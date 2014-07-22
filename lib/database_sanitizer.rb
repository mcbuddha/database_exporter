require 'database_sanitizer/version'
require 'active_record/comments'
require 'progress'

module DatabaseSanitizer
  CHUNK_SIZE = (ENV['CHUNK_SIZE'] || "1000").to_i
  class Source < ActiveRecord::Base
  end
end

require 'database_sanitizer/transformers'

module DatabaseSanitizer
  class << self
    def extract_transformer comment; comment ? comment[/sanitize: ?(\w+)/,1] : nil; end

    def read_comments conn, tables
      tables.inject({}) do |transformers, table|
        transformers[table.to_sym] = conn.retrieve_column_comments(table.to_sym).inject({}) do |table_transformers, column|
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
        ActiveRecord::Migration.suppress_messages { ActiveRecord::Base.connection.exec_query schema_src }
      end
    end

    def get_chunks table
      conn = Source.connection
      query = "SELECT count(*) FROM #{conn.quote_table_name table}"
      pg_query = "SELECT reltuples::bigint FROM pg_class WHERE relname=#{conn.quote table}"
      res = conn.adapter_name == 'PostgreSQL' ? (conn.exec_query(pg_query) rescue false) : false
      unless res
        puts 'Counting...'
        conn.exec_query(query)
      end
      res.rows[0][0].to_i / CHUNK_SIZE + 1
    end

    def export src, dest, opts={}
      duplicate_schema opts[:schema]
      tables = (opts[:tables] || src.tables.collect(&:to_s)) - (opts[:exclude] || [])
      transformers = read_comments dest, tables
      max_tbl_name_len = transformers.keys.map(&:length).sort.last || 0

      tables.with_progress('Exporting').each do |table|
        q_table = dest.quote_table_name table
        s_table = table.to_sym
        sel_query = "SELECT * FROM #{q_table} #{order_clause_for_table(s_table)} LIMIT #{CHUNK_SIZE} OFFSET "
        get_chunks(table).times_with_progress(table.rjust max_tbl_name_len) do |chunk_i|
          offset = chunk_i * CHUNK_SIZE
          result = src.exec_query sel_query + offset.to_s
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
          dest.exec_query ins_query.string
        end
      end
    end
    
    def order_clause_for_table s_table
      "ORDER BY id" if ActiveRecord::Base.connection.column_exists?(s_table, :id)
    end
  end
end
