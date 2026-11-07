# frozen_string_literal: true

class QueryRecipeComponent < ViewComponent::Base
  attr_reader :kind, :locale

  def initialize(kind: 'browse', portal: nil, locale: nil, enabled: nil)
    super
    @kind = kind.to_s
    @portal = portal
    @locale = (locale || I18n.locale).to_s
    @enabled = enabled
  end

  def render?
    return @enabled unless @enabled.nil?

    helpers.respond_to?(:query_recipes_enabled?) ? helpers.query_recipes_enabled? : false
  rescue StandardError
    false
  end

  def current_portal
    @portal.presence || (helpers.respond_to?(:portal_name) ? helpers.portal_name : 'MatPortal')
  end

  def current_locale
    @locale.presence || I18n.locale.to_s
  end

  def call
    <<~HTML.html_safe
      <div class="query-recipe-component dropdown d-inline-block"
           data-controller="query-recipe"
           data-query-recipe-kind-value="#{kind}"
           data-query-recipe-portal-value="#{current_portal}"
           data-query-recipe-locale-value="#{current_locale}"
           data-query-recipe-storage-key-value="ontoportal_query_recipes_v1">
        <button type="button"
                class="btn btn-outline-secondary query-recipe-trigger-btn"
                data-action="click->query-recipe#togglePanel"
                data-query-recipe-target="triggerButton"
                aria-expanded="false"
                aria-haspopup="dialog"
                aria-controls="query-recipe-panel-#{kind}"
                title="#{I18n.t('query_recipes.button_label')}">
          <svg class="icon-svg mr-1" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"></path></svg>
          <span>#{I18n.t('query_recipes.button_label')}</span>
        </button>
        <div id="query-recipe-panel-#{kind}"
             class="query-recipe-panel dropdown-menu p-3 shadow d-none"
             data-query-recipe-target="panel"
             role="dialog"
             aria-label="#{I18n.t('query_recipes.saved_recipes')}"
             aria-modal="false"
             style="min-width: 320px; max-width: 420px; z-index: 1050;">
          <div class="d-flex justify-content-between align-items-center mb-2 border-bottom pb-2">
            <h6 class="m-0 font-weight-bold">#{I18n.t('query_recipes.saved_recipes')}</h6>
            <button type="button"
                    class="close border-0 bg-transparent"
                    data-action="click->query-recipe#closePanel"
                    data-query-recipe-target="closeButton"
                    aria-label="#{I18n.t('query_recipes.cancel')}">&times;</button>
          </div>
          <div class="query-recipe-save-box mb-3">
            <label for="recipe-name-#{kind}" class="form-label small text-muted mb-1 d-block">#{I18n.t('query_recipes.save_current')}</label>
            <div class="input-group input-group-sm">
              <input type="text"
                     id="recipe-name-#{kind}"
                     class="form-control form-control-sm query-recipe-name-input"
                     placeholder="#{I18n.t('query_recipes.recipe_name_placeholder')}"
                     data-query-recipe-target="nameInput"
                     data-action="keydown->query-recipe#onNameKeydown">
              <div class="input-group-append">
                <button type="button"
                        class="btn btn-sm btn-primary query-recipe-save-btn"
                        data-action="click->query-recipe#saveCurrent"
                        data-query-recipe-target="saveButton">#{I18n.t('query_recipes.save')}</button>
              </div>
            </div>
          </div>
          <div class="query-recipe-message alert py-1 px-2 small mb-2 d-none"
               data-query-recipe-target="message"
               role="status"
               aria-live="polite"></div>
          <div class="query-recipe-list mb-2"
               data-query-recipe-target="list"
               role="region"
               aria-label="#{I18n.t('query_recipes.saved_recipes')}">
            <div class="text-muted small query-recipe-empty p-2 text-center"
                 data-query-recipe-target="emptyState">#{I18n.t('query_recipes.empty_state')}</div>
          </div>
          <div class="d-flex justify-content-between align-items-center pt-2 border-top">
            <div>
              <button type="button"
                      class="btn btn-sm btn-link p-0 mr-2 query-recipe-import-btn"
                      data-action="click->query-recipe#triggerImport"
                      data-query-recipe-target="importButton">#{I18n.t('query_recipes.import')}</button>
              <input type="file"
                     class="d-none"
                     accept=".json,application/json"
                     data-query-recipe-target="fileInput"
                     data-action="change->query-recipe#handleFileImport">
            </div>
            <div>
              <button type="button"
                      class="btn btn-sm btn-link text-danger p-0 query-recipe-clear-btn"
                      data-action="click->query-recipe#clearAll"
                      data-query-recipe-target="clearAllButton">#{I18n.t('query_recipes.clear_all')}</button>
            </div>
          </div>
          <div class="text-muted query-recipe-notice mt-2" style="font-size: 0.75rem;">#{I18n.t('query_recipes.local_storage_notice')}</div>
        </div>
      </div>
    HTML
  end
end
