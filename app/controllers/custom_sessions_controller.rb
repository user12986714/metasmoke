# frozen_string_literal: true

class CustomSessionsController < Devise::SessionsController
  protect_from_forgery except: :create, with: :exception

  @@first_factor = [] # rubocop:disable Style/ClassVars

  def new
    super
  end

  def create
    super do |user|
      if user.present? && user.enabled_2fa
        id = user.id
        @@first_factor << id
        sign_out user
        redirect_to(url_for(controller: :custom_sessions, action: :verify_2fa, uid: id)) && return
      end
    end
  end

  def destroy
    super
  end

  def verify_2fa; end

  def verify_code
    target_user = User.find params[:uid]

    if target_user.two_factor_token.blank?
      flash[:danger] = 'I have no idea how you got here, but something is very wrong.'
      redirect_to(root_path) && return
    end

    totp = ROTP::TOTP.new(target_user.two_factor_token)
    if totp.verify(params[:code], drift_ahead: 30, drift_behind: 30)
      if @@first_factor.include? params[:uid].to_i
        @@first_factor.delete params[:uid].to_i
        sign_in_and_redirect User.find(params[:uid])
      else
        flash[:danger] = "You haven't completed password authentication yet!"
        redirect_to new_session_path(target_user)
      end
    else
      flash[:danger] = "That's not the right code."
      redirect_to url_for(controller: :custom_sessions, action: :verify_2fa, uid: params[:uid])
    end
  end
end
