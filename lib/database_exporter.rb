require 'database_exporter/version'
require 'active_record/comments'
require 'progress'

module DatabaseExporter
  class Source < ActiveRecord::Base
  end
end

require 'database_exporter/transformers'

module DatabaseExporter
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

    def export src, dest, opts={}
      duplicate_schema opts[:schema]
      tables = (opts[:tables] || src.tables.collect(&:to_s)) - (opts[:exclude] || [])
      transformers = read_comments dest, tables

      max_tbl_name_len = transformers.keys.map(&:length).sort.last || 0
      tables.with_progress('Exporting').each do |table|
        result = src.exec_query "SELECT * FROM #{table}"
        cols = result.columns.join ','
        dest.transaction do
          result.rows.with_progress(table.rjust max_tbl_name_len).each_with_index do |src_row, row_i|
            values = result.columns.each_with_index.map do |col, col_i|
              transformer = transformers[table.to_sym][col.to_sym]
              dest.quote transformer ? transformer.(row_i, src_row[col_i]) : src_row[col_i]
            end
            dest.insert_sql "INSERT INTO #{dest.quote_table_name table} (#{cols}) VALUES (#{values.join ','})"
          end
        end
      end
    end
  end
end
