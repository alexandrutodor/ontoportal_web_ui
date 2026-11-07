class Admin::CatalogConfigurationController < ApplicationController
  before_action :authorize_admin
  before_action :load_catalog_metadata, only: [:show]
  before_action :load_catalog_data, only: [:show]

  CATALOG_PATH = "#{LinkedData::Client.settings.rest_url}/".freeze
  CATALOG_METADATA_URL = "#{LinkedData::Client.settings.rest_url}/catalog_metadata".freeze

  def show
    @catalog_groups = attributes_groups
    @catalog_metadata ||= session[:catalog_metadata] || load_catalog_metadata
    @catalog_data ||= session[:catalog_data] || load_catalog_data
  end

  def update
    config = sanitize_config_params
    response = update_remote_config(config)

    if response_successful?(response)
      @catalog_data = load_catalog_data(reload: true)
      session[:catalog_data] = @catalog_data
      @catalog_metadata = session[:catalog_metadata] || load_catalog_metadata
      @catalog_groups = attributes_groups

      respond_to do |format|
        format.turbo_stream do
          flash.now[:notice] = t('admin.catalog_configuration.configuration_updated_successfully')
          render turbo_stream: turbo_stream.replace(
            'catalog-config',
            render_to_string('admin/catalog_configuration/show')
          )
        end
        format.html do
          flash[:notice] = t('admin.catalog_configuration.configuration_updated_successfully')
          redirect_to admin_catalog_configuration_path
        end
      end
    else
      @catalog_metadata = session[:catalog_metadata] || load_catalog_metadata
      @catalog_groups = attributes_groups
      @catalog_data = build_editable_catalog_data(params[:config])
      flash.now[:alert] = t('admin.catalog_configuration.configuration_update_error', error: extract_update_error(response))

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            'catalog-config',
            render_to_string('admin/catalog_configuration/show')
          ), status: :unprocessable_entity
        end
        format.html do
          render :show, status: :unprocessable_entity
        end
      end
    end
  end

  def edit_nested_form
    # Use cached data from session, fallback to fresh fetch if needed
    @key = params[:key]&.to_sym
    return head :bad_request unless @key

    @catalog_data = session[:catalog_data] || load_catalog_data
    @catalog_metadata = session[:catalog_metadata] || load_catalog_metadata
    
    @value_attrs = @catalog_data&.dig(@key) || []
    @field_names = extract_field_names_for_key(@key)
    
    render partial: 'edit_nested_form_modal', layout: false
  end

  private

  def attributes_groups
    {
      general: %w[acronym title identifier versionInfo status],
      licensing: %w[accessRights rightsHolder license morePermissions],
      description: %w[
        description comment keyword alternative hiddenLabel 
        bibliographicCitation isReferencedBy
      ],
      dates: %w[created modified],
      agents: %w[
        creator contributor publisher contactPoint curatedBy 
        translator endorsedBy fundedBy funding
      ],
      community: %w[
        audience publishingPrinciples repository bugDatabase 
        mailingList toDoList award
      ],
      usage: %w[knownUsage coverage example themeTaxonomy],
      methodology_and_provenance: %w[accrualMethod accrualPeriodicity accrualPolicy],
      media: %w[associatedMedia depiction logo],
      other: %w[color federated_portals relation sampleQueries]
    }.freeze
  end

  def list_included_attributes
    attributes_groups.values.flatten.freeze
  end

  def agents_list
    %w[
      rightsHolder contactPoint creator contributor curatedBy 
      translator publisher endorsedBy
    ].freeze
  end

  def load_catalog_data(reload: false)
    return @catalog_data if @catalog_data && !reload

    params = build_catalog_params(exclude_agents: true)
    raw_catalog = LinkedData::Client::HTTP.get(CATALOG_PATH, params)
    data_hash = extract_hash_from_sdk(raw_catalog)

    agent_params = build_catalog_params(agents_only: true)
    raw_agents = LinkedData::Client::HTTP.get(CATALOG_PATH, agent_params)
    agents_hash = extract_hash_from_sdk(raw_agents)

    data_hash.merge!(agents_hash)
    @catalog_data = sanitize_catalog_data(data_hash)
    session[:catalog_data] = @catalog_data
    @catalog_data
  rescue StandardError => e
    Rails.logger.error("Failed to load catalog data: #{e.class}")
    flash.now[:alert] ||= t('admin.catalog_configuration.catalog_load_error', default: 'Problem retrieving catalog data')
    @catalog_data = session[:catalog_data] || {}
  end

  def load_catalog_metadata(reload: false)
    return @catalog_metadata if @catalog_metadata && !reload

    catalog_metadata_list = LinkedData::Client::HTTP.get(CATALOG_METADATA_URL, {})
    filtered_metadata = Array(catalog_metadata_list).select do |metadata| 
      metadata.respond_to?(:attribute) && list_included_attributes.include?(metadata.attribute) 
    end
    
    @catalog_metadata = filtered_metadata.index_by(&:attribute)
    session[:catalog_metadata] = @catalog_metadata
    @catalog_metadata
  rescue StandardError => e
    Rails.logger.error("Failed to load catalog metadata: #{e.class}")
    flash.now[:alert] ||= t('admin.catalog_configuration.metadata_load_error', default: 'Problem retrieving catalog metadata')
    @catalog_metadata = session[:catalog_metadata] || {}
  end

  def build_catalog_params(exclude_agents: false, agents_only: false)
    included_attrs = if agents_only
                      agents_list
                    elsif exclude_agents
                      list_included_attributes - agents_list
                    else
                      list_included_attributes
                    end

    {
      include: included_attrs.join(','),
      display_links: false,
      display_context: false,
      _ts: Time.current.to_i
    }
  end

  def update_remote_config(config)
    LinkedData::Client::HTTP.patch(CATALOG_PATH, config)
  rescue StandardError => e
    Rails.logger.error("Config update failed: #{e.class}")
    OpenStruct.new(status: 500, body: "Update failed: #{e.class}")
  end

  def sanitize_catalog_data(catalog_data)
    return {} unless catalog_data.is_a?(Hash)

    catalog_data_sanitized = catalog_data.dup
    # sanitize themeTaxonomy to let only the acronyms of the ontologies
    taxonomy = catalog_data_sanitized[:themeTaxonomy] || catalog_data_sanitized['themeTaxonomy']
    if taxonomy.is_a?(Array)
      r_url = rest_url.to_s
      cleaned = taxonomy.select { |url| url.is_a?(String) && (!r_url.empty? && url.start_with?(r_url)) }.map { |url| url.split('/').last }
      catalog_data_sanitized[:themeTaxonomy] = cleaned
    else
      catalog_data_sanitized[:themeTaxonomy] = []
    end
    catalog_data_sanitized
  end

  def sanitize_config_params
    config = params.require(:config).permit!.to_h

    list_included_attributes.each do |key|
      config[key] = sanitize_attribute_value(config[key.to_s])
    end

    config['rightsHolder'] = config['rightsHolder']&.first&.presence || '' if config['rightsHolder']

    # rebuild themeTaxonomy as URIs
    if config['themeTaxonomy'].is_a?(Array)
      r_url = rest_url.to_s.chomp('/')
      config['themeTaxonomy'] = config['themeTaxonomy'].map { |value| "#{r_url}/#{value}" }
      config['themeTaxonomy'] << "http://vocabularies.unesco.org/thesaurus"
    end
    config.compact
  end

  def response_successful?(response)
    return false if response.nil?

    if response.respond_to?(:status)
      st = response.status
      return [200, 204].include?(st.to_i) if st.is_a?(Integer) || (st.is_a?(String) && st =~ /^\d+$/)
    end
    false
  end

  def extract_hash_from_sdk(obj)
    return {} if obj.nil? || obj == {} || obj == []

    if obj.respond_to?(:errors) && obj.errors.present?
      raise StandardError, "SDK response contains errors: #{obj.errors}"
    end
    if obj.respond_to?(:error) && obj.error.present?
      raise StandardError, "SDK response contains error: #{obj.error}"
    end

    hash = if obj.is_a?(Hash)
             obj
           elsif obj.respond_to?(:to_hash) && !obj.is_a?(OpenStruct)
             obj.to_hash
           elsif obj.respond_to?(:to_h)
             begin
               obj.to_h
             rescue StandardError
               nil
             end
           end

    raise StandardError, "Unsupported SDK response shape: #{obj.class}" unless hash.is_a?(Hash)

    if hash[:errors].present? || hash['errors'].present? || hash[:error].present? || hash['error'].present?
      raise StandardError, "SDK response contains errors: #{hash[:errors] || hash['errors'] || hash[:error] || hash['error']}"
    end

    hash
  end

  def build_editable_catalog_data(submitted_params)
    known = (session[:catalog_data] || @catalog_data || {}).transform_keys(&:to_sym)
    return known unless submitted_params.is_a?(Hash) || submitted_params.is_a?(ActionController::Parameters)

    submitted = submitted_params.respond_to?(:to_unsafe_h) ? submitted_params.to_unsafe_h : submitted_params.to_h
    retained = known.dup

    cached_agents = {}
    agents_list.each do |agent_key|
      Array(known[agent_key.to_sym] || known[agent_key.to_s]).each do |ag|
        if ag.respond_to?(:id) && ag.id.present?
          cached_agents[ag.id.to_s] = ag
        elsif ag.is_a?(Hash) && (ag['id'] || ag[:id]).present?
          cached_agents[(ag['id'] || ag[:id]).to_s] = ag
        end
      end
    end

    submitted.each do |k, v|
      sym_key = k.to_sym
      if agents_list.include?(k.to_s)
        raw_ids = case v
                  when Hash, ActionController::Parameters
                    vh = v.respond_to?(:to_unsafe_h) ? v.to_unsafe_h : v.to_h
                    if vh['id'] || vh[:id]
                      [vh['id'] || vh[:id]]
                    else
                      vh.values.filter_map { |item| item.is_a?(Hash) ? (item['id'] || item[:id]) : nil }
                    end
                  when Array
                    v.filter_map { |item| item.is_a?(Hash) ? (item['id'] || item[:id]) : item }
                  when String
                    [v]
                  else
                    []
                  end
        raw_ids = raw_ids.map(&:to_s).reject(&:blank?)

        restored_agents = raw_ids.map do |id|
          cached_agents[id] || OpenStruct.new(id: id)
        end

        retained[sym_key] = if sym_key == :rightsHolder
                              restored_agents.first
                            else
                              restored_agents
                            end
      else
        retained[sym_key] = case v
                            when 'true' then true
                            when 'false' then false
                            when Array then v.reject(&:blank?)
                            else v
                            end
      end
    end
    retained
  end

  def extract_update_error(response)
    status = response.respond_to?(:status) ? response.status : nil
    if status.present? && status.to_i > 0
      "HTTP #{status.to_i}"
    else
      t('admin.catalog_configuration.update_unknown_error', default: 'Remote service rejected update')
    end
  end

  def sanitize_attribute_value(raw_value)
    return nil if raw_value.nil?

    case raw_value
    when Hash
      raw_value.values.filter_map { |v| v.is_a?(Hash) ? v['id'] : nil }
    when Array
      raw_value.reject(&:blank?)
    else
      raw_value
    end
  end

  def extract_field_names_for_key(key)
    metadata = @catalog_metadata[key.to_s]
    return [] unless metadata&.enforcedValues
    
    metadata.enforcedValues.flat_map do |field|
      field.to_h.keys - [:links, :context]
    end
  end


end