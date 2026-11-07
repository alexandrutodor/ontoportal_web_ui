# frozen_string_literal: true

class ClipboardComponent < ViewComponent::Base

  def initialize(icon: "icons/copy.svg", title: nil, message: nil, show_content: true)
    @icon = icon
    @title = title || I18n.t("components.clipboard.copy", default: "Copy")
    @message = message
    @show_content = show_content
  end

  def accessible_label
    raw_label = @title.presence || I18n.t("components.clipboard.copy", default: "Copy")
    plain = if defined?(ActionController::Base) && ActionController::Base.respond_to?(:helpers)
              ActionController::Base.helpers.strip_tags(raw_label)
            elsif respond_to?(:helpers) && helpers.respond_to?(:strip_tags)
              helpers.strip_tags(raw_label)
            else
              raw_label.to_s.gsub(/<[^>]*>/, "")
            end
    plain.presence || I18n.t("components.clipboard.copy", default: "Copy")
  end

  def copied_label
    I18n.t("components.clipboard.copied", default: "Copied!")
  end

  def failed_label
    I18n.t("components.clipboard.failed", default: "Copy failed")
  end
end
