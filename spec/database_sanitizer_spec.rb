require 'spec_helper'

describe DatabaseSanitizer do
  describe '#extract_transformer', nodb: true do
    context 'should return nil for no transformer' do
      ['no tag comment', nil, '', 'sanitize no tag'].each do |comment|
        it { expect(described_class.extract_transformer comment).to be_nil }
      end
    end

    context 'should return transformer' do
      [
       'sanitize: test_tr',
       'random sanitize: test_tr comment',
       'some sanitize: test_tr, sanitize: other',
       'without sanitize:test_tr space',
       'trailing sanitize: test_tr'
      ].each do |comment|
        it { expect(described_class.extract_transformer comment).to eq('test_tr') }
      end
    end
  end

  describe '#extract_order', nodb: true do
    context 'should return nil for no order' do
      ['no order comment', nil, '', 'order_by no tag'].each do |comment|
        it { expect(described_class.extract_order comment).to be_nil }
      end
    end

    context 'should return order' do
      [
       'order_by: test_col',
       'random order_by: test_col comment',
       'some order_by: test_col, order_by: other',
       'without order_by:test_col space',
       'trailing order_by: test_col'
      ].each do |comment|
        it { expect(described_class.extract_order comment).to eq('test_col') }
      end
    end
  end

  describe '#read_comments' do
    before do
      DatabaseSanitizer::Source.connection.execute <<-SQL
ALTER TABLE test
  ADD COLUMN field3 character varying(255),
  ADD COLUMN field4 character varying(255)
;
SQL
      comments = {
        field1: 'comment no tag',
        field2: nil,
        field3: 'comment sanitize: name',
        field4: 'sanitize:email'
      }.each { |col, com| DatabaseSanitizer::Source.connection.set_column_comment :test, col, com }
    end

    context 'some defined' do
      it 'should get transformers' do
        transformers = described_class.read_comments([:test])[:test]
        expect(transformers[:field1]).to be_nil
        expect(transformers[:field2]).to be_nil
        expect(transformers[:field3]).to be_kind_of(Proc)
        expect(transformers[:field4]).to be_kind_of(Proc)
      end
    end

    context 'some undefined' do
      before { DatabaseSanitizer::Source.connection.set_column_comment :test, :field2, 'sanitize:undef' }
      it 'should abort' do
        expect(lambda {described_class.read_comments [:test]}).to raise_error(SystemExit)
      end
    end
  end

  describe '#insert_query' do
    context 'empty db' do
      let(:result) { Struct.new(:rows, :columns).new([], []) }
      it { expect(described_class.insert_query '"test"', :test, {}, result, 0).to eq('') }
    end
  end

  describe '#order_clause' do
    context 'no order comment' do
      context 'and no id' do
        before do
          DatabaseSanitizer::Source.connection.execute 'ALTER TABLE test DROP COLUMN IF EXISTS id;'
        end

        it 'should not order' do
          expect(described_class.order_clause :test).to be_nil
        end
      end

      context 'and id' do
        it 'should order by id' do
          expect(described_class.order_clause :test).to end_with('id')
        end
      end
    end
  end

  context 'order comment' do
    before { DatabaseSanitizer::Source.connection.set_table_comment :test, 'order_by: field2' }

    it 'should order by comment' do
      expect(described_class.order_clause :test).to end_with(DatabaseSanitizer::Source.connection.quote_table_name 'field2')
    end
  end
end
