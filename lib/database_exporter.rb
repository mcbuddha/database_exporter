require 'database_exporter/version'

require 'activerecord_comments'
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
        t_sym = table
        transformers[t_sym] = conn.retrieve_column_comments(t_sym).inject({}) do |table_transformers, column|
          transformer_key = extract_transformer column[1]
          unless transformer_key.nil? || Transformers.include?(transformer_key)
            abort "Transformer '#{transformer_key}' not found (#{table}.#{column_sym})" 
          end
          table_transformers[column[0]] = transformer_key && Transformers[transformer_key]
          table_transformers
        end
        transformers
      end
    end

    def duplicate_schema
      source_schema = StringIO.new
      ActiveRecord::SchemaDumper.dump(Source.connection, source_schema)
      ActiveRecord::Migration.suppress_messages { eval source_schema.string }
    end

    def export opts={}
      duplicate_schema
      tables = opts[:tables] || Source.connection.tables.collect(&:to_s)
      tables -= opts[:exclude] || []

      transformers = read_comments Source.connection, tables
      max_col_name_len = transformers.map{|k,v|v.keys}.flatten.map(&:length).sort.last

      tables.with_progress('Exporting').each do |table|
        result = Source.connection.exec_query "SELECT * FROM #{table}"
        cols = result.columns.join ','
        dest.transaction do
          result.rows.with_progress(table.rjust max_col_name_len).each_with_index do |src_row, row_i|
            values = result.columns.each_with_index.map do |col, col_i|
              transformer = transformers[table][col]
              dest.quote transformer ? Transformers[transformer].(row_i, src_row[col_i]) : src_row[col_i]
            end
            dest.insert_sql "INSERT INTO #{table} (#{cols}) VALUES (#{values.join ','})"
          end
          sql = "INSERT INTO #{table} (#{cols}) VALUES (#{values.join ','})"
          ActiveRecord::Base.connection.insert_sql sql
        end
      end
    end
  end
end
