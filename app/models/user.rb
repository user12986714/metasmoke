# frozen_string_literal: true

require 'open-uri'

class User < ApplicationRecord
  include Websocket

  rolify
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :feedbacks, dependent: :nullify
  has_many :api_tokens, dependent: :destroy
  has_many :api_keys, dependent: :nullify
  has_many :user_site_settings, dependent: :destroy
  has_many :flag_conditions, dependent: :destroy
  has_many :flag_logs, dependent: :nullify
  has_many :smoke_detectors, dependent: :destroy
  has_many :moderator_sites, dependent: :destroy
  has_many :reviews, class_name: 'ReviewResult', dependent: :nullify
  has_many :post_comments, dependent: :nullify

  has_one :channels_user, required: false, dependent: :destroy

  validate :gdpr_bollocks

  # All accounts start with flagger role enabled
  after_create do
    add_role :flagger if SiteSetting['auto_flagger_role']

    message = case stack_exchange_account_id.present?
              when true
                "New metasmoke user ['#{username}'](//stackexchange.com/users/#{stack_exchange_account_id}) created"
              when false
                "New metasmoke user '#{username}' created"
              end

    if SiteSetting['new_account_messages_enabled']
      SmokeDetector.send_message_to_charcoal message
    end
  end

  before_save do
    # Retroactively update
    (changed & %w[stackexchange_chat_id meta_stackexchange_chat_id stackoverflow_chat_id]).each do
      # todo
    end
  end

  def self.smokey
    # Return the account matching SmokeDetector
    User.where(stack_exchange_account_id: 4606062).first # rubocop:disable Style/NumericLiterals
  end

  def active_for_authentication?
    super && roles.present?
  end

  def inactive_message
    if !has_role?(:reviewer)
      :not_approved
    else
      super # Use whatever other message
    end
  end

  def update_chat_ids
    return if stack_exchange_account_id.nil?

    ids = [[:stackexchange_chat_id, 'stackexchange.com'], [:stackoverflow_chat_id, 'stackoverflow.com'],
           [:meta_stackexchange_chat_id, 'meta.stackexchange.com']].map do |s|
      res = Net::HTTP.get_response(URI.parse("https://chat.#{s[1]}/accounts/#{stack_exchange_account_id}"))
      begin
        chat_id = res['location'].scan(%r{/users/(\d+)/})[0][0]
      rescue
        chat_id = nil
      end
      [s[0], chat_id]
    end.to_h

    update ids
  end

  def get_username(readonly_api_token = nil)
    if readonly_api_token.nil?
      Rails.logger.error 'User#get_username called without readonly_api_token'
      Rails.logger.error caller.join("\n")
      return
    end

    begin
      config = AppConfig['stack_exchange']
      auth_string = "key=#{config['key']}&access_token=#{readonly_api_token}"

      resp = Net::HTTP.get_response(URI.parse("https://api.stackexchange.com/2.2/me/associated?pagesize=1&filter=!ms3d6aRI6N&#{auth_string}"))
      resp = JSON.parse(resp.body)

      first_site = URI.parse(resp['items'][0]['site_url']).host

      resp = Net::HTTP.get_response(URI.parse("https://api.stackexchange.com/2.2/me?site=#{first_site}&filter=!-.wwQ56Mfo3J&#{auth_string}"))
      resp = JSON.parse(resp.body)

      return resp['items'][0]['display_name']
    rescue => ex
      Rails.logger.error "Error raised while fetching username: #{ex.message}"
      Rails.logger.error ex.backtrace
    end
  end

  def self.blacklist_managers
    Role.where(name: :blacklist_manager).first.users
  end

  def remember_me
    true
  end

  # Flagging

  def update_moderator_sites
    return if stack_exchange_account_id.nil?

    page = 1
    has_more = true
    new_moderator_sites = []
    auth_string = "key=#{AppConfig['stack_exchange']['key']}"
    while has_more
      params = "?page=#{page}&pagesize=100&filter=!6OrReH6NRZrmc&#{auth_string}"
      url = "https://api.stackexchange.com/2.2/users/#{stack_exchange_account_id}/associated" + params

      response = JSON.parse(Net::HTTP.get_response(URI.parse(url)).body)
      has_more = response['has_more']
      page += 1

      response['items'].each do |network_account|
        next unless network_account['user_type'] == 'moderator'
        domain = Addressable::URI.parse(network_account['site_url']).host
        new_moderator_sites << ModeratorSite.find_or_create_by(site_id: Site.find_by(site_domain: domain).id,
                                                               user_id: id)
      end

      sleep response['backoff'].to_i if response.include?('backoff')
    end

    self.moderator_sites = new_moderator_sites

    save!
  end

  def flag(flag_type, post, dry_run = false, **opts)
    if moderator_sites.pluck(:site_id).include? post.site_id
      return false, 'User is a moderator on this site'
    end

    return false, 'Flags not enabled for this account' unless flags_enabled

    path = post.answer? ? 'answers' : 'questions'
    site = post.site

    tstore = AppConfig['token_store']
    acct_id = stack_exchange_account_id
    post_id = post.native_id
    post_type = path
    r = HTTParty.get("#{tstore['host']}/autoflag/options",
                     headers: {
                       'X-API-Key': tstore['key']
                     },
                     query: {
                       account_id: acct_id,
                       site: site.api_parameter,
                       post_id: post_id,
                       post_type: post_type[0..-2]
                     })
    return false, "[beta] /autoflag/options #{r.code}\n#{r.headers}\n#{r.body}" if r.code != 200
    response = JSON.parse(r.body)

    flag_options = response['items']

    if flag_options.blank?
      return false,
        if response['error_message'] == 'The account associated with the access_token does not have a user on the site'
          'No account on this site.'
        else
          'Flag options not present'
        end
    end

    flag_strings = {
      spam: ['spam', 'contenido no deseado', 'スパム', 'спам'],
      abusive: ['rude or abusive', 'rude ou abusivo', 'irrespetuoso o abusivo', '失礼又は暴言', 'невежливый или оскорбительный'],
      other: ['in need of moderator intervention', 'precisa de atenção dos moderadores', 'se necesita la intervención de un moderador',
              'モデレーターによる対応が必要です', 'требуется вмешательство модератора']
    }

    unless flag_strings.keys.include? flag_type.to_sym
      return false, "Unrecognized flag type #{flag_type} specified in call to User#flag"
    end

    flag_option = flag_options.find do |fo|
      flag_strings[flag_type.to_sym].include? fo['title']
    end

    return false, 'Flag option not present' if flag_option.blank?

    return true, 0 if dry_run
    tstore = AppConfig['token_store']
    acct_id = stack_exchange_account_id
    post_id = post.native_id
    flag_option_id = flag_option['option_id']
    post_type = path
    comment = opts[:comment]
    req = HTTParty.post("#{tstore['host']}/autoflag",
                        headers: {
                          'X-API-Key': tstore['key']
                        }, query: {
                          account_id: acct_id,
                          site: site.api_parameter,
                          post_id: post_id,
                          post_type: post_type[0..-2],
                          flag_option_id: flag_option_id,
                          comment: comment
                        })
    return false, "[beta] /autoflag #{req.code}\n#{req.headers}\n#{req.body}" if req.code != 200
    flag_response = JSON.parse(req.body)

    # rubocop:disable Style/GuardClause
    if flag_response.include?('error_id') || flag_response.include?('error_message')
      return false, flag_response['error_message']
    else
      return true, (flag_response.include?('backoff') ? flag_response['backoff'] : 0)
    end
    # rubocop:enable Style/GuardClause
  end

  def spam_flag(post, dry_run = false)
    flag :spam, post, dry_run
  end

  def abusive_flag(post, dry_run = false)
    flag :abusive, post, dry_run
  end

  def other_flag(post, comment)
    flag :other, post, false, comment: comment
  end

  def moderator?
    moderator_sites.any?
  end

  def can_use_regex_search?
    (has_role? :reviewer) || moderator_sites.any?
  end

  private

  def gdpr_bollocks
    errors.add(:privacy_accepted, "must be agreed to if you're an EU resident") unless !eu_resident || privacy_accepted
  end
end
