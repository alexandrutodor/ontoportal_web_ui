import { Application } from "@hotwired/stimulus"

const application = Application.start()

// Configure Stimulus development experience
application.debug = false
window.Stimulus   = application


import Flatpickr from "stimulus-flatpickr"

application.register("flatpickr", Flatpickr);
import NestedForm from 'stimulus-rails-nested-form'
application.register('nested-form', class extends NestedForm {
  // The removed row takes its focused button with it; keep keyboard users in the form.
  remove(event) {
    super.remove(event)
    this.element.querySelector('.add-another-object')?.focus()
  }
})
import ReadMore from 'stimulus-read-more'
application.register('read-more', ReadMore)
import Timeago from 'stimulus-timeago'
application.register('timeago', Timeago)
export { application }


