require_relative 'bolt.rb'

module Carto
  class GhostTablesManager
    MUTEX_REDIS_KEY = 'ghost_tables_working'.freeze
    MUTEX_TTL_MS = 600000
    MAX_TABLES_FOR_SYNC_RUN = 8

    def initialize(user_id)
      @user_id = user_id
    end

    def user
      @user ||= ::User[@user_id]
    end

    def link_ghost_tables
      return if user_tables_synced_with_db?

      if should_run_synchronously?
        link_ghost_tables_synchronously
      else
        link_ghost_tables_asynchronously
      end
    end

    def link_ghost_tables_synchronously
      sync_user_tables_with_db unless user_tables_synced_with_db?
    end

    def link_ghost_tables_asynchronously
      ::Resque.dequeue(::Resque::UserDBJobs::UserDBMaintenance::LinkGhostTablesByUsername, @user.username)
      ::Resque.enqueue(::Resque::UserDBJobs::UserDBMaintenance::LinkGhostTablesByUsername, @user.username)
    end

    # determine linked tables vs cartodbfied tables consistency; i.e.: needs to run
    def user_tables_synced_with_db?
      user_tables = fetch_user_tables
      cartodbfied_tables = fetch_cartodbfied_tables

      user_tables.length == cartodbfied_tables.length &&
        (user_tables - cartodbfied_tables).empty? &&
        (cartodbfied_tables - user_tables).empty?
    end

    def get_bolt
      Carto::Bolt.new("#{user.username}:#{MUTEX_REDIS_KEY}", ttl_ms: MUTEX_TTL_MS)
    end

    # run a block of code exclusively with GhostTablesManager (using Bolt lock)
    # if warning_params is provided (with paramters for Logger.warning) then
    # the code is executed even if the lock is not acquired (in which case
    # a warning is emmitted)
    def self.run_synchronized(user_id, attempts: 10, timeout: 30000, **warning_params)
      gtm = new(user_id)
      bolt = gtm.get_bolt
      lock_acquired = bolt.run_locked(attempts: attempts, timeout: timeout) do
        yield
      end
      if !lock_acquired && warning_params.present?
        # run even if lock wasn't aquired
        CartoDB::Logger.warning(warning_params)
        yield
      end
    end

    private

    # It's nice to run sync if any unsafe stale (dropped or renamed) tables will be shown to the user but we can't block
    # the workers for more that 180 seconds
    def should_run_synchronously?
      cartodbfied_tables = fetch_cartodbfied_tables

      dropped_and_stale_tables = find_dropped_tables(cartodbfied_tables) + find_stale_tables(cartodbfied_tables)
      total_tables_to_be_linked = dropped_and_stale_tables + find_new_tables(cartodbfied_tables)

      dropped_and_stale_tables.count != 0 && total_tables_to_be_linked.count < MAX_TABLES_FOR_SYNC_RUN
    end

    def sync_user_tables_with_db
      got_locked = get_bolt.run_locked(fail_function: lambda { link_ghost_tables_asynchronously }) { sync }
    end

    def sync
      cartodbfied_tables = fetch_cartodbfied_tables.sort_by(&:id)
      user_tables = fetch_user_tables.sort_by(&:id)

      ci = 0
      ui = 0
      new_cartodbfied_ids = []
      missing_user_tables_ids = []
      renamed_tables = []

      # Find which ids are new, which existed but have changed names, and which one have dissapeared
      while (ci < cartodbfied_tables.size && ui < user_tables.size)
        cdb_table = cartodbfied_tables[ci]
        user_table = user_tables[ui]
        if (cdb_table.id < user_table.id)
          new_cartodbfied_ids << cdb_table
          ci += 1
        elsif (cdb_table.id == user_table.id)
          if (cdb_table.name != user_table.name)
            renamed_tables << cdb_table
          end
          ci += 1
          ui += 1
        else
          missing_user_tables_ids << user_table
          ui += 1
        end
      end

      new_cartodbfied_ids += cartodbfied_tables[ci, cartodbfied_tables.size - ci] if ci < cartodbfied_tables.size
      missing_user_tables_ids += user_tables[ui, user_tables.size - ui] if ui < user_tables.size

      # Out of the extracted ids we need to know which one are truly new tables, which ones are
      # regenerated tables (the underlying ids have changed, but the name remains) and which ones
      # have been completely deleted
      regenerated_tables = new_cartodbfied_ids.select do |cartodbfied_table|
            missing_user_tables_ids.any?{|t| t.name == cartodbfied_table.name}
        end
      new_tables = new_cartodbfied_ids - regenerated_tables
      dropped_tables = missing_user_tables_ids.reject do |dropped_table|
            regenerated_tables.any?{|t| t.name == dropped_table.name}
        end

      # Update table_id on UserTables with physical tables with changed oid. Should go first.
      regenerated_tables.each(&:regenerate_user_table)

      # Relink tables that have been renamed through the SQL API
      renamed_tables.each(&:rename_user_table_vis)

      # Create UserTables for non linked Tables
      new_tables.each(&:create_user_table)

      # Unlink tables that have been created through the SQL API. Should go last.
      dropped_tables.each(&:drop_user_table)
    end

    # Any UserTable that has been renamed or regenerated.
    def find_stale_tables(cartodbfied_tables)
      find_regenerated_tables(cartodbfied_tables) | find_renamed_tables(cartodbfied_tables)
    end

    # UserTables that coincide with a cartodbfied table in name but not id
    def find_renamed_tables(cartodbfied_tables)
      user_tables = fetch_user_tables

      cartodbfied_tables.select do |cartodbfied_table|
        user_tables.any?{|t| t.name != cartodbfied_table.name && t.id == cartodbfied_table.id}
      end
    end

    # UserTables that coincide with a cartodbfied table in id but not in name
    def find_regenerated_tables(cartodbfied_tables)
      user_tables = fetch_user_tables

      cartodbfied_tables.select do |cartodbfied_table|
        user_tables.any?{|t| t.name == cartodbfied_table.name && t.id != cartodbfied_table.id}
      end
    end

    # Cartodbfied tables that are not stale and are not linked as UserTables yet
    def find_new_tables(cartodbfied_tables)
      cartodbfied_tables - fetch_user_tables - find_stale_tables(cartodbfied_tables)
    end

    # UserTables that are not stale and have no cartodbfied table associated to it
    def find_dropped_tables(cartodbfied_tables)
      fetch_user_tables - cartodbfied_tables - find_stale_tables(cartodbfied_tables)
    end

    # Fetches all currently linked user tables
    def fetch_user_tables
      Carto::UserTable.select([:name, :table_id]).where(user_id: @user_id).map do |record|
        Carto::TableFacade.new(record[:table_id], record[:name], @user_id)
      end
    end

    # Fetches all linkable tables: non raster cartodbfied + raster
    def fetch_cartodbfied_tables
      sql = %{
        WITH tables_with_proper_owner_and_schema AS
        (
            SELECT c.oid, c.relname
            FROM pg_catalog.pg_class c
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE   c.relowner IN (#{user.get_database_roles.map{ |r| "to_regrole(\'#{r}\')" }.join(',')})
                AND c.relkind = 'r'
                AND n.nspname = '#{user.database_schema}'
        ),
        tables_with_columns AS
        (
            SELECT attrelid FROM
            (
                SELECT attrelid,
                    SUM(
                            CASE WHEN attname = 'cartodb_id' THEN 100
                                WHEN attname = 'the_geom' THEN 1
                                WHEN attname = 'the_geom_webmercator' THEN 1
                                WHEN attname = 'the_raster_webmercator' THEN 10
                                ELSE 0
                            END) as ncolumns
                FROM pg_attribute
                WHERE   attname IN ('cartodb_id','the_geom','the_geom_webmercator', 'the_raster_webmercator')
                        AND    attnum > 0
                        AND    NOT attisdropped
                GROUP BY attrelid
            ) all_tables WHERE ncolumns = 102 OR ncolumns >= 110
        ),
        tables_with_trigger AS
        (
            SELECT tgrelid
            FROM pg_trigger
            WHERE tgname = 'test_quota_per_row'
        )
        SELECT t1.relname as table_name, t1.oid as reloid
        FROM tables_with_proper_owner_and_schema t1
        INNER JOIN tables_with_columns t2 ON (t1.oid = t2.attrelid)
        INNER JOIN tables_with_trigger t3 ON (t1.oid = t3.tgrelid)
      }

      user.in_database(as: :superuser)[sql].all.map do |record|
        Carto::TableFacade.new(record[:reloid], record[:table_name], @user_id)
      end
    end
  end

  class TableFacade
    attr_reader :id, :name, :user_id

    def initialize(id, name, user_id)
      @id = id
      @name = name
      @user_id = user_id
    end

    def user
      @user ||= ::User[@user_id]
    end

    def user_table_with_matching_id
      user.tables.where(table_id: id).first
    end

    def user_table_with_matching_name
      user.tables.where(name: name).first
    end

    def create_user_table
      user_table = Carto::UserTable.new
      user_table.user_id = user.id
      user_table.table_id = id
      user_table.name = name
      new_table = ::Table.new(user_table: user_table)

      new_table.register_table_only = true
      new_table.keep_user_database_table = true

      new_table.save
    rescue StandardError => exception
      CartoDB::Logger.error(message: 'Ghost tables: Error creating UserTable',
                            exception: exception,
                            user: user,
                            table_name: name,
                            table_id: id)
    end

    def rename_user_table_vis
      user_table_vis = user_table_with_matching_id.table_visualization

      user_table_vis.register_table_only = true
      user_table_vis.name = name

      user_table_vis.store
    rescue StandardError => exception
      CartoDB::Logger.error(message: 'Ghost tables: Error renaming Visualization',
                            exception: exception,
                            user: user,
                            table_name: name,
                            table_id: id)
    end

    def drop_user_table
      user_table_to_drop = user.tables.where(table_id: id, name: name).first
      return unless user_table_to_drop # The table has already been deleted

      table_to_drop = ::Table.new(user_table: user_table_to_drop)
      table_to_drop.keep_user_database_table = true
      table_to_drop.destroy
    rescue StandardError => exception
      CartoDB::Logger.error(message: 'Ghost tables: Error dropping Table',
                            exception: exception,
                            user: user,
                            table_name: name,
                            table_id: id)
    end

    def regenerate_user_table
      user_table_to_regenerate = user_table_with_matching_name

      user_table_to_regenerate.table_id = id
      user_table_to_regenerate.save
    rescue StandardError => exception
      CartoDB::Logger.error(message: 'Ghost tables: Error syncing table_id for UserTable',
                            exception: exception,
                            user: user,
                            table_name: name,
                            table_id: id)
    end

    def eql?(other)
      id.eql?(other.id) && name.eql?(other.name) && user.id.eql?(other.user_id)
    end

    def ==(other)
      eql?(other)
    end

    def hash
      [id, name, user_id].hash
    end
  end
end
