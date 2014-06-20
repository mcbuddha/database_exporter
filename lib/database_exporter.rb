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
      schema_comments
    end

    def duplicate_schema
      source_schema = StringIO.new
      ActiveRecord::SchemaDumper.dump(DatabaseExporter::Source.connection, source_schema)
      ActiveRecord::Migration.suppress_messages { eval source_schema.string }
    end

    def export opts={}
      duplicate_schema
      sch = schema_comments
      max_col_name_len = sch.map{|k,v|v[:columns].keys}.flatten.map(&:length).sort.last

      tables = opts[:tables] || sch.keys.collect(&:to_s)
      tables -= opts[:exclude] || []
      tables.with_progress('Exporting').each do |table|
        result = DatabaseExporter::Source.connection.exec_query "SELECT * FROM #{table}"
        cols = result.columns.join ','
        result.rows.with_progress(table.rjust max_col_name_len).each_with_index do |src_row, row_i|
          values = result.columns.each_with_index.map do |col, col_i|
            col_comment = DatabaseExporter::Source.connection.retrieve_column_comment(table.to_sym, col.to_sym)
            value =
              if col_comment
                if DatabaseExporter::Transformers.has_key?(col_comment)
                  DatabaseExporter::Transformers[col_comment].(row_i, src_row[col_i])
                else
                  warn "Transformer '#{col_comment}' not found"
                  nil
                end
              else src_row[col_i]
              end
            ActiveRecord::Base.connection.quote value
          end
          sql = "INSERT INTO #{table} (#{cols}) VALUES (#{values.join ','})"
          ActiveRecord::Base.connection.insert_sql sql
        end
      end
    end
  end
end
