# frozen_string_literal: true

class LinkTextComponent < ViewComponent::Base
  include InternationalisationHelper

  def initialize(text:, icon: nil, target: nil)
    @text = text
    @icon = icon
    @target = target
  end

  def call
    svg_icon = !@icon&.empty? ? inline_svg(@icon, width: '14px', height: '14px') : ''
    extra_span = @text == t('mappings.upload_mappings') ? '' : content_tag(:span, svg_icon, class: 'mx-1')
    safe_join([@text, extra_span], '')
  end
end
