# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true

  def self.match_search(term, with_search_score: true, **cols)
    sanitized = sanitize_for_search term, **cols
    if with_search_score
      select(Arel.sql("`#{table_name}`.*, #{sanitized} AS search_score")).where(sanitized)
    else
      where(sanitized)
    end
  end

  def self.sanitize_name(name)
    name.to_s.delete('`').insert(0, '`').insert(-1, '`')
  end

  def match_search(term, **cols)
    ApplicationRecord.match_search(term, **cols)
  end

  def self.sanitize_for_search(term, **cols)
    cols = cols.map do |k, v|
      if v.is_a?(Array)
        v.map { |vv| "#{sanitize_name k}.#{sanitize_name vv}" }.join(', ')
      else
        "#{sanitize_name k}.#{sanitize_name v}"
      end
    end.join(', ')

    ActiveRecord::Base.send(:sanitize_sql_array, ["MATCH (#{cols}) AGAINST (? IN BOOLEAN MODE)", term])
  end

  def self.sanitize_like(unsafe, *args)
    sanitize_sql_like unsafe, *args
  end

  def self.mass_habtm(join_table, first_type, second_type, record_pairs)
    first_ids = record_pairs.map { |p| p[0].id }.join(', ')
    second_ids = record_pairs.map { |p| p[1].id }.join(', ')
    pre_existing = connection.execute("SELECT #{first_type}_id, #{second_type}_id FROM #{join_table} " \
                                      "WHERE #{first_type}_id IN (#{first_ids}) AND #{second_type}_id IN (#{second_ids})").to_a

    record_ids = record_pairs.map do |pair|
      pair_ids = [pair[0].id, pair[1].id]
      pre_existing.include?(pair_ids) ? nil : pair_ids
    end.compact

    values = record_ids.map { |p| "(#{p[0]}, #{p[1]})" }.join(', ')
    query = "INSERT INTO #{join_table} (#{first_type}_id, #{second_type}_id) VALUES #{values};"
    connection.execute query
  end

  def self.fields(*names)
    names.map { |n| "#{table_name}.#{n}" }
  end
end
