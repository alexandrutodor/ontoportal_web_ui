# frozen_string_literal: true

class Input::LanguageSelectorComponent < ViewComponent::Base
  include InternationalisationHelper
  def initialize(languages:, selected: nil,  id: '', name: '' , enable_all: false, **html_options)
    super
    @languages = languages
    @id = id
    @name = name
    @selected = selected
    @data = html_options[:data] || {}
    @enable_all = enable_all
    @html_options = html_options
  end

  def languages
    values = []
    values = [["<div>#{render(LanguageFieldComponent.new(label: t('components.all_languages'), icon: 'icons/earth.svg', value: 'en'))}</div>", 'all']] if @enable_all

    @languages.each do |key, label|
      option = "<div>#{render(LanguageFieldComponent.new(value: key.to_s.downcase, label: label, auto_label: true))}</div>"
      values += [[option, key.to_s.downcase]]
    end
    values
  end

  def call
    data = @data.merge('select-input-is-language-value': true)
    render SelectInputComponent.new(id: @id, name: @name, values: languages,
                                    selected: @selected,
                                    data: data,
                                    is_language: true,
                                    required: true,
                                    open_to_add_values: false,
                                    placeholder: t('components.select_anguage'),
                                    **@html_options.except(:data))
  end
end
