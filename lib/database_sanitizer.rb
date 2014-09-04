require 'database_sanitizer/version'
require 'active_record/comments'
require 'progress'

module DatabaseSanitizer
  CHUNK_SIZE = (ENV['CHUNK_SIZE'] || "1000").to_i
  class Source < ActiveRecord::Base
  end
  class Destination < ActiveRecord::Base
  end
end

require 'database_sanitizer/transformers'

module DatabaseSanitizer
  class << self
    def extract_transformer comment; comment ? comment[/sanitize: ?(\w+)/,1] : nil; end

    def extract_order comment; comment ? comment[/order_by: ?(\w+)/,1] : nil; end

    def read_comments tables
      tables.inject({}) do |transformers, table|
        transformers[table.to_sym] = Source.connection.retrieve_column_comments(table.to_sym).inject({}) do |table_transformers, column|
          transformer_key = extract_transformer column[1]
          unless transformer_key.nil? || Transformers.include?(transformer_key)
            abort "Transformer '#{transformer_key}' not found (#{table}.#{column[0]})"
          end
          table_transformers[column[0]] = transformer_key && Transformers[transformer_key]
          table_transformers
        end
        transformers
      end
    end

    def duplicate_schema schema=nil
      schema_src = nil
      if schema.nil?
        schema_sio = StringIO.new
        puts 'Dumping schema.rb...'
        ActiveRecord::SchemaDumper.dump(Source.connection, schema_sio)
        puts 'Loading schema.rb...'
        ActiveRecord::Migration.suppress_messages { eval schema_sio.string }
      else
        puts 'Reading schema SQL...'
        schema_src = IO.read File.expand_path(schema, Dir.pwd)
        ActiveRecord::Migration.suppress_messages { Destination.connection.execute schema_src }
      end
    end

    def get_chunks conn, table
      query = "SELECT count(*) FROM #{conn.quote_table_name table}"
      pg_query = "SELECT reltuples::bigint FROM pg_class WHERE relname=#{conn.quote table}"
      res = conn.adapter_name == 'PostgreSQL' ? (conn.exec_query(pg_query) rescue false) : false
      unless res
        puts 'Counting...'
        conn.exec_query(query)
      end
      res.rows[0][0].to_i / CHUNK_SIZE + 1
    end

    def export opts={}
      duplicate_schema opts[:schema]
      tables = (opts[:tables] || Source.connection.tables.collect(&:to_s)) - (opts[:exclude] || [])
      transformers = read_comments tables
      max_tbl_name_len = transformers.keys.map(&:length).sort.last || 0

      tables.with_progress('Exporting').each do |table|
        export_table table, transformers, max_tbl_name_len
      end
    end

    def export_table table, transformers, max_tbl_name_len
      q_table = Destination.connection.quote_table_name table
      s_table = table.to_sym
      order_column = order_column_for s_table
      last_value = nil

      suspend_triggers table do
        get_chunks(Source.connection, table).times_with_progress(table.rjust max_tbl_name_len) do |chunk_i|
          offset = chunk_i * CHUNK_SIZE
          result = Source.connection.exec_query select_query q_table, order_column, last_value, offset
          Destination.connection.execute insert_query q_table, s_table, transformers, result, offset

          last_value = result.last[order_column] if result.any?
        end
      end
    end

    def suspend_triggers table
      Destination.connection.execute "ALTER TABLE #{table} DISABLE TRIGGER ALL"
      yield
      Destination.connection.execute "ALTER TABLE #{table} ENABLE TRIGGER ALL"
    end

    def insert_query q_table, s_table, transformers, result, offset
      dest = Destination.connection
      cols = result.columns.map { |col| dest.quote_column_name col }.join ','
      ins_query_part = "INSERT INTO #{q_table} (#{cols}) VALUES ("
      ins_query = StringIO.new
      result.rows.each_with_index do |src_row, row_i|
        values = result.columns.each_with_index.map do |col, col_i|
          transformer = transformers[s_table][col.to_sym]
          dest.quote transformer ? transformer.(offset + row_i, src_row[col_i]) : src_row[col_i]
        end
        ins_query << ins_query_part << values.join(',') << '); '
      end
      ins_query.string
    end

    def select_query q_table, order_column, last_value, offset
      query = "SELECT * FROM #{q_table} "
      query << "WHERE #{order_column} > #{last_value} " if last_value.present?
      query << "ORDER BY #{order_column} " if order_column.present?
      query << "LIMIT #{CHUNK_SIZE} "
      query << "OFFSET #{offset} " unless order_column.present?
      query
    end

    def order_column_for s_table
      src = Source.connection
      order_by = extract_order src.retrieve_table_comment s_table
      if order_by
        src.quote_table_name(order_by)
      elsif src.column_exists? s_table, :id
        'id'
      else
        nil
      end
    end
  end
end
