# frozen_string_literal: true

class SpamDomain < ApplicationRecord
  include Websocket

  has_many :post_spam_domains
  has_many :posts, through: :post_spam_domains, after_add: :setup_review
  has_and_belongs_to_many :domain_tags, after_add: :check_dq
  has_and_belongs_to_many :domain_groups
  has_one :review_item, as: :reviewable
  has_many :abuse_reports, as: :reportable
  has_many :left_links, class_name: 'DomainLink', foreign_key: :left_id
  has_many :right_links, class_name: 'DomainLink', foreign_key: :right_id

  validates :domain, uniqueness: true

  after_create :fix_asn_tags

  def fix_asn_tags
    asn_query = `dig +short "$(dig +short '#{domain.tr("'", '')}' | awk -F. '/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $4"."$3"." $2"."$1;exit}').origin.asn.cymru.com" TXT` # rubocop:disable Metrics/LineLength
    asn = asn_query.strip.tr('"', '').split('|')[0]&.strip
    return unless asn.present?
    prev_domain_tags = domain_tags.where(special: true).select(:name).map(&:name).select { |dt| dt.start_with?('AS-') }
    asn.split.each do |as|
      desc = `dig +short AS#{as}.asn.cymru.com TXT`.strip.tr('"', '').split('|')[-1]&.strip
      tag = DomainTag.find_or_create_by(name: "AS-#{as}", special: true)
      tag.update(description: "Domains under the Autonomous System Number #{as} - #{desc}.") unless tag.description.present?
      if prev_domain_tags.include? "AS-#{as}"
        prev_domain_tags -= ["AS-#{as}"]
      else
        domain_tags << tag
      end
    end
    prev_domain_tags.each do |dtn|
      domain_tags.delete(DomainTag.find_by(name: dtn))
    end
  end

  after_create do
    groups = Rails.cache.fetch 'domain_groups' do
      DomainGroup.all.map { |dg| !dg.regex ? nil : [Regexp.new(dg.regex), dg.id] }.compact.to_h
    end
    groups.keys.each do |r|
      DomainGroup.find(groups[r]).spam_domains << self if r.match? domain
    end
  end

  def links
    left_links.or right_links
  end

  def linked_domains
    SpamDomain.where(id: links.select(Arel.sql("IF(left_id = #{id}, right_id, left_id)")))
  end

  def should_dq?(_item)
    domain_tags.count > 0
  end

  def review_item_name
    domain
  end

  private

  def setup_review(*_args)
    return unless posts.count >= 3 && domain_tags.count == 0 && !review_item.present?
    if posts.map(&:is_fp).any?(&:!)
      ReviewItem.create(reviewable: self, queue: ReviewQueue['untagged-domains'], completed: false)
    else
      domain_tags << DomainTag.find_or_create_by(name: 'notspam')
    end
  end

  def check_dq(*_args)
    return unless review_item.present? && should_dq?(review_item)
    review_item.update(completed: true)
  end
end
