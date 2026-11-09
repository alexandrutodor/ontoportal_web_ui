require 'uri'
require 'cgi'

module SearchHelper
  def search_content_params
    query = params[:search].presence || '*'
    page = params[:page].to_i > 0 ? params[:page].to_i : 1
    page_size = params[:page_size].to_i > 0 ? params[:page_size].to_i : 100
    [query, page, page_size]
  end

  def render_search_paginated_list(container_id:, next_page_url:, child_url:, child_turbo_frame:,
                         child_param:, show_count: nil, lang: request_lang,
                         auto_click: false, results: , next_page: ,total_count:, submission: @submission )
    query, page, page_size = search_content_params

    @results = OpenStruct.new
    @results.nextPage = next_page
    @results.page = page
    @results.totalCount = total_count
    @results.collection = results.map { |x| o = OpenStruct.new(x); o.id = x[:name]; o }
    @results.collection = @results.collection.drop(1) # remove ontology
    @search = query

    selected = params[child_param.to_sym].blank? && page.eql?(1) ? @results.collection.first&.id : params[child_param.to_sym]

    next_page_link = nil
    if @results.nextPage
      base_url, query_str = next_page_url.to_s.split('?', 2)
      query_params = query_str.present? ? URI.decode_www_form(query_str).to_h : {}
      query_params.reject! { |_, v| v.blank? }

      query_params['search'] = @search if @search.present?
      query_params['page'] = @results.nextPage.to_s
      query_params['page_size'] = page_size.to_s if page_size
      query_params['lang'] = lang.to_s if lang.present?
      query_params[child_param.to_s] = selected.to_s if selected.present?

      query_params['type'] = params[:type].to_s if query_params['type'].blank? && params[:type].present?
      query_params['types'] = params[:types].to_s if query_params['types'].blank? && params[:types].present?
      query_params['ontologies'] = params[:ontologies].to_s if query_params['ontologies'].blank? && params[:ontologies].present?

      query_string = query_params.respond_to?(:to_query) ? query_params.to_query : URI.encode_www_form(query_params)
      next_page_link = query_string.empty? ? base_url : "#{base_url}?#{query_string}"
    end

    child_url_with_lang = child_url.include?('?') ? "#{child_url}&lang=#{CGI.escape(lang.to_s)}" : "#{child_url}?lang=#{CGI.escape(lang.to_s)}"

    if show_count && page.eql?(1)
      [
        replace("#{container_id}_count", content_tag(:span, @results.totalCount).html_safe),
        prepend("#{container_id}_view-page-1", paginated_list_component(id: container_id,
                                                                                        results: @results,
                                                                                        next_page_url: next_page_link,
                                                                                        child_url: child_url_with_lang,
                                                                                        child_param: child_param,
                                                                                        child_turbo_frame: child_turbo_frame,
                                                                                        open_in_modal: show_count,
                                                                                        selected: selected, submission: submission))
      ]
    else
      paginated_list_component(id: container_id,
                               results: @results,
                               next_page_url: next_page_link,
                               child_url: child_url_with_lang,
                               child_param: child_param,
                               child_turbo_frame: child_turbo_frame,
                               open_in_modal: show_count,
                               selected: selected,
                               auto_click: auto_click, submission: submission)
    end
  end
end
