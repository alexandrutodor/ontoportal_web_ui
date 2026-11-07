# In test/integration/login_flows_test.rb

require 'test_helper'

require_relative '../helpers/application_test_helpers'

class LoginFlowsTest < ActionDispatch::IntegrationTest
  include ApplicationTestHelpers::Users


  setup do
    @user_john = fixtures(:users)[:john]
    @user_bob = fixtures(:users)[:bob]
    @user_bob = create_user(@user_bob)
    @created_user = nil
  end

  teardown do
    delete_user(@created_user) if @created_user
    delete_user(@user_bob)
    delete_user(@user_john)
    TestResourceOwnership.reset! if defined?(TestResourceOwnership) && TestResourceOwnership.empty?
  end

  test 'go to sign up page, save, and see account details' do
    get root_url
    assert_response :success

    get login_index_url
    assert_response :success

    get new_user_path

    new_user = OpenStruct.new(@user_john.to_h)
    unique_suffix = defined?(TestResourceOwnership) ? TestResourceOwnership.namespace_suffix.sub(/\A_+/, '') : "t#{Time.now.to_i % 100000}#{rand(1000..9999)}"
    new_user.username = "tj_#{unique_suffix}"
    new_user.email = "#{new_user.username}@example.com"

    begin
      post users_path, params: {
        user: {
          firstName: new_user.firstName,
          lastName: new_user.lastName,
          username: new_user.username,
          orcidId: new_user.orcidId,
          githubId: new_user.githubId,
          email: new_user.email,
          password: new_user.password,
          password_confirmation: new_user.password,
          terms_and_conditions: true
        }
      }
    rescue StandardError => e
      TestResourceOwnership.mark_outcome_unknown(:user, new_user.username) if defined?(TestResourceOwnership)
      raise e
    end

    confirmed_user = session[:user] || (@controller.instance_variable_get(:@user_saved) if defined?(@controller) && @controller)
    user_acknowledged = confirmed_user &&
                        confirmed_user.respond_to?(:username) &&
                        confirmed_user.username.to_s == new_user.username.to_s &&
                        confirmed_user.respond_to?(:id) &&
                        !confirmed_user.id.to_s.strip.empty? &&
                        (!defined?(ApplicationTestHelpers) || !ApplicationTestHelpers.sdk_error_response?(confirmed_user))

    if user_acknowledged
      TestResourceOwnership.register(:user, confirmed_user) if defined?(TestResourceOwnership)
      @created_user = confirmed_user
    elsif response.redirection?
      TestResourceOwnership.mark_outcome_unknown(:user, new_user.username) if defined?(TestResourceOwnership)
    end

    assert_redirected_to "/my-ontologies"
    follow_redirect!

    assert_select '.notification', text: 'Account was successfully created'

    get "/accounts/#{new_user.username}"
    assert_response :success

    assert_select '.account-page-title', text: 'My account'

    assert_select '.title', text: 'First name:'
    assert_select '.info', text: new_user.firstName

    assert_select '.title', text: 'Last name:'
    assert_select '.info', text: new_user.lastName

    assert_select '.title', text: 'Email:'
    assert_select '.info', text: new_user.email

    assert_select '.title', text: 'Username:'
    assert_select '.info', text: new_user.username

    assert_select '.title', text: 'ORCID:'
    assert_select '.info', text: new_user.orcidId

    assert_select '.title', text: 'GitHub account:'
    assert_select '.info', text: new_user.githubId
  end

  test 'go to login page and click save' do
    get login_index_url
    assert_response :success
    post login_index_url, params: {
      user: {
        username: @user_bob.username,
        password: @user_bob.password
      }
    }

    assert_redirected_to root_url
    follow_redirect!

    assert_select '.notification', text: "Welcome #{@user_bob.username}!"
  end
end
