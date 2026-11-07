class Input::InputFieldComponent < ViewComponent::Base
    def initialize(label: "" , name:, value: '', type: 'text', placeholder: "", error_message: "", helper_text: "", disabled: false, readonly: false, data: nil, id: '', min: '', max: '', step: '', tooltip: nil)
        @label = label
        @name = name
        @placeholder  = placeholder
        @error_message = error_message
        @helper_text = helper_text
        @value = value
        @type = type
        @disabled = disabled
        @readonly = readonly
        @id = id
        @data = data
        @min = min
        @max = max
        @step = step
        @tooltip = tooltip
    end


    def error_style
        "border-color: var(--error-color);" if error?
    end

    def error?
        !@error_message&.empty?
    end

    def help?
        !@helper_text.blank?
    end

    def label?
        !@label&.empty?
    end

    def control_id
        @id.presence || (@name.present? ? sanitize_to_id(@name) : nil)
    end

    def error_id
        "#{control_id}_error" if error? && control_id.present?
    end

    def help_id
        "#{control_id}_help" if help? && control_id.present?
    end

    def aria_describedby
        [error_id, help_id].compact.join(' ').presence
    end
end


