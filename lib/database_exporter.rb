require 'database_exporter/version'

require 'schema_comments'

module DatabaseExporter
  class Source < ActiveRecord::Base
  end
end

require 'database_exporter/transformers'

require 'progress'

module DatabaseExporter
  class << self
    def schema_comments
      schema_comments = {}
      source = DatabaseExporter::Source.connection
      source.tables.each do |table|
        t_sym = table.to_sym
        schema_comments[t_sym] = {
          comment: source.retrieve_table_comment(t_sym),
          columns: source.retrieve_column_comments(t_sym)
        }
      end
      schema_comments
    end

    def duplicate_schema
      source_schema = StringIO.new
      ActiveRecord::SchemaDumper.dump(DatabaseExporter::Source.connection, source_schema)
      eval source_schema.string
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
                else nil
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
