require "rails_helper"

RSpec.describe SubscribeMailer, type: :mailer do
  around(:each) do |example|
    orig_announce_list = $ANNOUNCE_LIST
    orig_announce_service_host = $ANNOUNCE_SERVICE_HOST
    orig_announce_list_service = $ANNOUNCE_LIST_SERVICE
    orig_support_email = $SUPPORT_EMAIL

    $ANNOUNCE_LIST = "appliance-users-request@localhost"
    $ANNOUNCE_SERVICE_HOST = "lists.example.org"
    $ANNOUNCE_LIST_SERVICE = "SYMPA"
    $SUPPORT_EMAIL = "support@example.org"
    begin
      example.run
    ensure
      $ANNOUNCE_LIST = orig_announce_list
      $ANNOUNCE_SERVICE_HOST = orig_announce_service_host
      $ANNOUNCE_LIST_SERVICE = orig_announce_list_service
      $SUPPORT_EMAIL = orig_support_email
    end
  end

  describe "register for announce list" do
    let(:mail) { SubscribeMailer.register_for_announce_list("user@lirmm.fr","user_fn","user_ln") }

    it "renders the headers" do
      expect(mail.subject).to eq("subscribe #{$ANNOUNCE_LIST} user_fn user_ln")
      expect(mail.to).to eq([$ANNOUNCE_SERVICE_HOST])
      expect(mail.bcc).to eq([$SUPPORT_EMAIL])
      expect(mail.from).to eq(["user@lirmm.fr"])
    end

    it "renders the body" do
      expect(mail.body.encoded).to eq("")
    end

  end

  describe "unregister for announce list" do
    let(:mail) { SubscribeMailer.unregister_for_announce_list("user@lirmm.fr") }

    it "renders the headers" do
      expect(mail.subject).to eq("unsubscribe #{$ANNOUNCE_LIST}")
      expect(mail.to).to eq([$ANNOUNCE_SERVICE_HOST])
      expect(mail.bcc).to eq([$SUPPORT_EMAIL])
      expect(mail.from).to eq(["user@lirmm.fr"])
    end

    it "renders the body" do
      expect(mail.body.encoded).to eq("")
    end

  end

end
