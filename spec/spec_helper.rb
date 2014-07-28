$: << File.expand_path('../lib', __FILE__)

require 'yaml'
require 'pry'

require 'database_sanitizer'

DBCONF = YAML::load(IO.read(File.expand_path('../config/database.yml', __FILE__)))
ENV['DB'] ||= 'postgres'
src_conf = DBCONF[ENV['DB']]
dest_conf = src_conf.update({'datbase' => "#{src_conf['database']}_sanitized"})
DatabaseSanitizer::Source.establish_connection(src_conf).connection
DatabaseSanitizer::Destination.establish_connection(dest_conf).connection

RSpec.configure do |c|
  c.around(:each) do |ex|
    unless ex.metadata[:nodb]
      DatabaseSanitizer::Source.connection.execute <<-SQL
CREATE TABLE test (
  id integer NOT NULL,
  field1 character varying(255),
  field2 integer
);
SQL
    end
    ex.run
    DatabaseSanitizer::Source.connection.drop_table :test unless ex.metadata[:nodb]
  end
end

