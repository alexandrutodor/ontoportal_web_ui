require 'cgi'

module NotesHelper
  include ActionView::Helpers::TagHelper
  include ActionView::Helpers::OutputSafetyHelper

  NOTES_TAGS = %w(a br b em strong i)

  def recurse_replies(replies)
    return "" if replies.nil?
    html = ""
    replies.each do |reply|
      reply_html = <<-html
        <div class="reply">
          <div class="reply_author">
            <b>#{get_username(reply.creator)}</b> #{time_ago_in_words(DateTime.parse(@note.created))} ago
          </div>
          <div class="reply_body">
            #{sanitize reply.body, tags: NOTES_TAGS}<br/>
          </div>
          <div class="reply_meta">
            <a href="#reply" class="reply_reply" data-parent-id="#{reply.id}" data-parent-type="reply">reply</a>
          </div>
          <div class="discussion">
            <div class="discussion_container">
              #{recurse_replies(reply.respond_to?(:children) ? reply.children : nil)}
            </div>
          </div>
        </div>
      html
      html << reply_html
    end
    html
  end

  def proposal_html(note)
    return "" unless note.respond_to?(:proposal) && note.proposal

    rows = case note.proposal.type
    when "ProposalNewClass"
      [
        content_tag(:tr, content_tag(:th, "Reason for Change") + content_tag(:td, note.proposal.reasonForChange)),
        content_tag(:tr, content_tag(:th, "Contact Info") + content_tag(:td, note.proposal.contactInfo)),
        content_tag(:tr, content_tag(:th, "Preferred Name") + content_tag(:td, note.proposal.label)),
        content_tag(:tr, content_tag(:th, "Provisional id") + content_tag(:td, note.proposal.classId)),
        content_tag(:tr, content_tag(:th, "Parent") + content_tag(:td, note.proposal.parent)),
        content_tag(:tr, content_tag(:th, "Synonyms") + content_tag(:td, safe_join(Array(note.proposal.synonym), ", "))),
        content_tag(:tr, content_tag(:th, "Definition") + content_tag(:td, safe_join(Array(note.proposal.definition), ", ")))
      ]
    when "ProposalChangeHierarchy"
      [
        content_tag(:tr, content_tag(:th, "Relationship Type") + content_tag(:td, safe_join(Array(note.proposal.newRelationshipType), ", "))),
        content_tag(:tr, content_tag(:th, "New Relationship Target") + content_tag(:td, note.proposal.newTarget, colspan: 3)),
        content_tag(:tr, content_tag(:th, "Old Relationship Target") + content_tag(:td, note.proposal.oldTarget, colspan: 3)),
        content_tag(:tr, content_tag(:th, "Reason for Change") + content_tag(:td, note.proposal.reasonForChange)),
        content_tag(:tr, content_tag(:th, "Contact Info") + content_tag(:td, note.proposal.contactInfo))
      ]
    when "ProposalChangeProperty"
      [
        content_tag(:tr, content_tag(:th, "Property id") + content_tag(:td, note.proposal.propertyId)),
        content_tag(:tr, content_tag(:th, "New Property Value") + content_tag(:td, note.proposal.newValue, colspan: 3)),
        content_tag(:tr, content_tag(:th, "Old Property Value") + content_tag(:td, note.proposal.oldValue, colspan: 3)),
        content_tag(:tr, content_tag(:th, "Reason for Change") + content_tag(:td, note.proposal.reasonForChange)),
        content_tag(:tr, content_tag(:th, "Contact Info") + content_tag(:td, note.proposal.contactInfo))
      ]
    end

    rows ? content_tag(:table, safe_join(rows), class: "proposal") : nil
  end

  def get_note_type_text(note_type)
    case note_type
    when "Comment"
      return t('notes.comment')
    when "ProposalNewClass"
      return t('notes.new_class_proposal')
    when "ProposalChangeHierarchy"
      return t('notes.new_relationship_proposal')
    when "ProposalChangeProperty"
      return t('notes.change_property_value_proposal')
    end
  end
  

  def delete_button
    user = session[:user]
    # TODO_REV: Enable anonymous user
    # user ||= anonymous_user

    params = "data-bp_user_id='#{user.id}'"
    spinner = '<span class="delete_notes_spinner" style="display: none;">' + image_tag("spinners/spinner_000000_16px.gif", style: "vertical-align: text-bottom;") + '</span>'
    error = "<span style='color: red;' class='delete_notes_error'></span>"
    return "<a href='#' onclick='deleteNotes(this);return false;' style='display: inline-block !important;' class='notes_delete link_button' #{params}>Delete selected notes</a> #{spinner} #{error}"
  end

end
