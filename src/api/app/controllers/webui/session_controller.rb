class Webui::SessionController < Webui::WebuiController
  before_action :kerberos_auth, only: [:new]

  skip_before_action :check_anonymous, only: [:new, :create, :sso, :sso_callback]

  def new
    switch_to_webui2
  end

  def create
    user = User.find_with_credentials(params[:username], params[:password])

    unless user
      RabbitmqBus.send_to_bus('metrics', 'login,access_point=webui,failure=unauthenticated value=1')
      redirect_to(session_new_path, error: 'Authentication failed')
      return
    end

    unless user.is_active?
      RabbitmqBus.send_to_bus('metrics', 'login,access_point=webui,failure=disabled value=1')
      redirect_to(root_path, error: 'Your account is disabled. Please contact the administrator for details.')
      return
    end

    User.session = user
    session[:login] = user.login
    Rails.logger.debug "Authenticated as user '#{user.login}'"
    RabbitmqBus.send_to_bus('metrics', 'login,access_point=webui value=1')

    redirect_on_login
  end

  def destroy
    Rails.logger.info "Logging out: #{session[:login]}"

    reset_session
    RabbitmqBus.send_to_bus('metrics', 'logout,access_point=webui value=1')
    User.session = nil

    redirect_on_logout
  end

  def sso
    switch_to_webui2
  end

  def sso_callback
    @auth_hash = request.env['omniauth.auth']
    auth_info = @auth_hash['info']
    auth_info['provider'] = @auth_hash['provider']

    user = User.find_with_omniauth(auth_info)

    unless user
      username = User.derive_username(auth_info)

      begin
        user = User.create_with_omniauth(auth_info, username)
      rescue ActiveRecord::ActiveRecordError => e
        Rails.logger.error "Failed to create #{username}: '#{e.inspect}'"
        Rails.logger.debug "auth_info: '#{auth_info.inspect}'"
      end

      unless user
        flash[:error] = "Failed to create a user"
        redirect_to root_path
      end
    end

    unless user.is_active?
      RabbitmqBus.send_to_bus('metrics', 'login,access_point=webui,failure=disabled value=1')
      redirect_to(root_path, error: 'Your account is disabled. Please contact the administrator for details.')
      return
    end

    User.session = user
    session[:login] = user.login
    Rails.logger.debug "Authenticated user '#{user.login}'"

    redirect_on_login
  end

  private

  def redirect_on_login
    if !referer_was_ours?
      redirect_to root_path
    elsif referer_was_login?
      redirect_to user_show_path(User.session!)
    else
      redirect_back(fallback_location: root_path)
    end
  end

  def redirect_on_logout
    if CONFIG['proxy_auth_mode'] == :on
      redirect_to CONFIG['proxy_auth_logout_page']
    else
      redirect_to root_path
    end
  end

  def referer_was_ours?
    return false unless request.referer

    parsed = URI.parse(request.referer)
    parsed.host == request.host and parsed.port == request.port
  end

  def referer_was_login?
    return false unless request.referer

    parsed = URI.parse(request.referer)
    return false unless parsed.host == request.host
    return false unless parsed.port == request.port

    parsed.path == session_new_path or parsed.path.starts_with?(sso_path)
  end
end
