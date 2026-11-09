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
    helpers.strip_tags(raw_label).presence || I18n.t("components.clipboard.copy", default: "Copy")
  end

  def copied_label
    I18n.t("components.clipboard.copied", default: "Copied!")
  end

  def failed_label
    I18n.t("components.clipboard.failed", default: "Copy failed")
  end
end
