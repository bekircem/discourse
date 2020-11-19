# frozen_string_literal: true

require_relative '../base'
require_relative 'support/settings'
require_relative 'database/database'
require_relative 'importers/importer_factory'

module ImportScripts::PhpBB3
  class Importer < ImportScripts::Base
    # @param settings [ImportScripts::PhpBB3::Settings]
    # @param database [ImportScripts::PhpBB3::Database_3_0 | ImportScripts::PhpBB3::Database_3_1]
    def initialize(settings, database)
      @settings = settings
      super()

      @database = database
      @php_config = database.get_config_values
      @importers = ImporterFactory.new(@database, @lookup, @uploader, @settings, @php_config)
    end

    def perform
      super if settings_check_successful?
    end

    protected

    def execute
      puts '', "importing from phpBB #{@php_config[:phpbb_version]}"

      if @settings.category_mapping.present?
        puts "category mapping is present. enabling tagging"
        SiteSetting.tagging_enabled = true
      end

      import_users
      import_anonymous_users if @settings.import_anonymous_users
      import_groups
      import_user_groups
      import_mapped_categories
      import_categories
      import_posts
      import_private_messages if @settings.import_private_messages
      import_bookmarks if @settings.import_bookmarks
    end

    def change_site_settings
      super

      @importers.permalink_importer.change_site_settings
    end

    def get_site_settings_for_import
      settings = super

      max_file_size_kb = @database.get_max_attachment_size
      settings[:max_image_size_kb] = [max_file_size_kb, SiteSetting.max_image_size_kb].max
      settings[:max_attachment_size_kb] = [max_file_size_kb, SiteSetting.max_attachment_size_kb].max

      # temporarily disable validation since we want to import all existing images and attachments
      SiteSetting.type_supervisor.load_setting(:max_image_size_kb, max: settings[:max_image_size_kb])
      SiteSetting.type_supervisor.load_setting(:max_attachment_size_kb, max: settings[:max_attachment_size_kb])

      settings
    end

    def settings_check_successful?
      true
    end

    def import_users
      puts '', 'creating users'
      total_count = @database.count_users
      importer = @importers.user_importer
      last_user_id = 0

      batches do |offset|
        rows, last_user_id = @database.fetch_users(last_user_id)
        rows = rows.to_a.uniq { |row| row[:user_id] }
        break if rows.size < 1

        next if all_records_exist?(:users, importer.map_users_to_import_ids(rows))

        create_users(rows, total: total_count, offset: offset) do |row|
          begin
            importer.map_user(row)
          rescue => e
            log_error("Failed to map user with ID #{row[:user_id]}", e)
          end
        end
      end
    end

    def import_anonymous_users
      puts '', 'creating anonymous users'
      total_count = @database.count_anonymous_users
      importer = @importers.user_importer
      last_username = ''

      batches do |offset|
        rows, last_username = @database.fetch_anonymous_users(last_username)
        break if rows.size < 1

        next if all_records_exist?(:users, importer.map_anonymous_users_to_import_ids(rows))

        create_users(rows, total: total_count, offset: offset) do |row|
          begin
            importer.map_anonymous_user(row)
          rescue => e
            log_error("Failed to map anonymous user with ID #{row[:user_id]}", e)
          end
        end
      end
    end

    def import_groups
      puts '', 'creating groups'
      rows = @database.fetch_groups

      create_groups(rows) do |row|
        begin
          next if row[:group_type] == 3

          group_name = if @settings.site_name.present?
            "#{@settings.site_name}_#{row[:group_name]}"
          else
            row[:group_name]
          end[0..19].gsub(/[^a-zA-Z0-9\-_. ]/, '_')

          bio_raw = @importers.text_processor.process_raw_text(row[:group_desc]) rescue row[:group_desc]

          {
            id: @settings.prefix(row[:group_id]),
            name: group_name,
            full_name: row[:group_name],
            bio_raw: bio_raw
          }
        rescue => e
          log_error("Failed to map group with ID #{row[:group_id]}", e)
        end
      end
    end

    def import_user_groups
      puts '', 'creating user groups'
      rows = @database.fetch_group_users

      rows.each do |row|
        group_id = @lookup.group_id_from_imported_group_id(@settings.prefix(row[:group_id]))
        next if !group_id

        user_id = @lookup.user_id_from_imported_user_id(@settings.prefix(row[:user_id]))

        begin
          GroupUser.find_or_create_by(user_id: user_id, group_id: group_id, owner: row[:group_leader])
        rescue => e
          log_error("Failed to add user #{row[:user_id]} to group #{row[:group_id]}", e)
        end
      end
    end

    def import_mapped_categories
      puts '', 'creating mapped categories'

      # Build an array of mapped categories and their ancestors. It is later
      # used to ensure that parent categories are created before children
      # categories.
      mapped_categories = []
      @settings.category_mapping.each do |_, value|
        next if value == :skip
        value.length.times.each do |idx|
          mapped_categories << value[0..idx]
        end
      end
      mapped_categories.uniq!
      mapped_categories.sort! do |a, b|
        a.length == b.length ? a.join <=> b.join : a.length <=> b.length
      end

      # Create mapped categories
      mapped_category_ids = {}
      res = create_categories(mapped_categories) do |row|
        *parent_categories, category_name = row
        {
          id: @settings.prefix(row.join(",")),
          name: category_name,
          parent_category_id: mapped_category_ids[parent_categories],
          post_create_action: proc do |category|
            mapped_category_ids[row] = category.id
          end
        }
      end

      # Replace mapped category names with their ID
      @settings.category_mapping.each do |key, value|
        next if value == :skip
        @settings.category_mapping[key] = @lookup.category_id_from_imported_category_id(@settings.prefix(value.join(",")))
      end

      puts "category_mapping = #{@settings.category_mapping.inspect}"
      puts "tags_mapping = #{@settings.tags_mapping.inspect}"
    end

    def import_categories
      puts '', 'creating categories'
      rows = @database.fetch_categories
      importer = @importers.category_importer

      create_categories(rows) do |row|
        next if @settings.category_mapping[row[:forum_id]] == :skip
        importer.map_category(row)
      end
    end

    def import_posts
      puts '', 'creating topics and posts'
      total_count = @database.count_posts
      importer = @importers.post_importer
      last_post_id = 0

      batches do |offset|
        rows, last_post_id = @database.fetch_posts(last_post_id)
        break if rows.size < 1

        next if all_records_exist?(:posts, importer.map_to_import_ids(rows))

        create_posts(rows, total: total_count, offset: offset) do |row|
          begin
            importer.map_post(row)
          rescue => e
            log_error("Failed to map post with ID #{row[:post_id]}", e)
          end
        end
      end
    end

    def import_private_messages
      puts '', 'creating private messages'
      total_count = @database.count_messages
      importer = @importers.message_importer
      last_msg_id = 0

      batches do |offset|
        rows, last_msg_id = @database.fetch_messages(last_msg_id)
        break if rows.size < 1

        next if all_records_exist?(:posts, importer.map_to_import_ids(rows))

        create_posts(rows, total: total_count, offset: offset) do |row|
          begin
            importer.map_message(row)
          rescue => e
            log_error("Failed to map message with ID #{row[:msg_id]}", e)
          end
        end
      end
    end

    def import_bookmarks
      puts '', 'creating bookmarks'
      total_count = @database.count_bookmarks
      importer = @importers.bookmark_importer
      last_user_id = last_topic_id = 0

      batches do |offset|
        rows, last_user_id, last_topic_id = @database.fetch_bookmarks(last_user_id, last_topic_id)
        break if rows.size < 1

        create_bookmarks(rows, total: total_count, offset: offset) do |row|
          importer.map_bookmark(row)
        end
      end
    end

    def update_last_seen_at
      # no need for this since the importer sets last_seen_at for each user during the import
    end

    # Do not use the bbcode_to_md in base.rb. It will be used in text_processor.rb instead.
    def use_bbcode_to_md?
      false
    end

    def batches
      super(@settings.database.batch_size)
    end

    def log_error(message, e)
      puts message
      puts e.message
      puts e.backtrace.join("\n")
    end
  end
end
