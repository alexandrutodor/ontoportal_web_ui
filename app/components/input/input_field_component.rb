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

    # Derive an id only for a rendered label; unlabeled repeated rows would otherwise share ids.
    def control_id
        @id.presence || (label? ? derived_id : nil)
    end

    def derived_id
        sanitize_to_id(@name) if @name.present?
    end

    def error_id
        base = control_id || derived_id
        "#{base}_error" if error? && base.present?
    end

    def help_id
        base = control_id || derived_id
        "#{base}_help" if help? && base.present?
    end

    def aria_describedby
        [error_id, help_id].compact.join(' ').presence
    end
end


