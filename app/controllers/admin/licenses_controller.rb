class Admin::LicensesController < ApplicationController
  prepend_before_action :authorize_admin

  def index
    @licenses = License.current_license
  end

  def new
    @license = License.new
  end

  def create
    @license = License.new(license_params)

    if @license.is_trial? || @license.encrypted_key.to_s.strip.casecmp?('trial')
      @license.errors.add(:encrypted_key, :trial_not_allowed)
      render :new, status: :unprocessable_entity
    elsif @license.save
      render :create_success
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def license_params
    params.require(:license).permit(:encrypted_key)
  end

end
