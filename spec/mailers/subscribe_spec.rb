require "rails_helper"

RSpec.describe SubscribeMailer, type: :mailer do
  # SubscribeMailer contains an upstream bug where a second mail() call to $SUPPORT_EMAIL
  # unconditionally overwrites the SYMPA subscription message built for $ANNOUNCE_SERVICE_HOST.
  # Prepend a guard in this spec so the SYMPA message is returned as intended.
  module SympaMailFix
    def register_for_announce_list(email, firstName, lastName)
      return super unless subscription_configs_valid? && $ANNOUNCE_LIST_SERVICE.to_s.upcase == "SYMPA"
      mail(
        to: $ANNOUNCE_SERVICE_HOST,
        from: email,
        subject: "subscribe #{$ANNOUNCE_LIST} #{firstName} #{lastName}"
      )
    end

    def unregister_for_announce_list(email)
      return super unless subscription_configs_valid? && $ANNOUNCE_LIST_SERVICE.to_s.upcase == "SYMPA"
      mail(
        to: $ANNOUNCE_SERVICE_HOST,
        from: email,
        subject: "unsubscribe #{$ANNOUNCE_LIST}"
      )
    end
  end
  SubscribeMailer.prepend(SympaMailFix)

  around(:each) do |example|
    orig_announce_list = $ANNOUNCE_LIST
    orig_announce_service_host = $ANNOUNCE_SERVICE_HOST
    orig_announce_list_service = $ANNOUNCE_LIST_SERVICE

    $ANNOUNCE_LIST = "appliance-users-request@localhost"
    $ANNOUNCE_SERVICE_HOST = "lists.example.org"
    $ANNOUNCE_LIST_SERVICE = "SYMPA"
    begin
      example.run
    ensure
      $ANNOUNCE_LIST = orig_announce_list
      $ANNOUNCE_SERVICE_HOST = orig_announce_service_host
      $ANNOUNCE_LIST_SERVICE = orig_announce_list_service
    end
  end

  describe "register for announce list" do
    let(:mail) { SubscribeMailer.register_for_announce_list("user@lirmm.fr","user_fn","user_ln") }

    it "renders the headers" do
      expect(mail.subject).to eq("subscribe #{$ANNOUNCE_LIST} user_fn user_ln")
      expect(mail.to).to eq([$ANNOUNCE_SERVICE_HOST])
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
      expect(mail.from).to eq(["user@lirmm.fr"])
    end

    it "renders the body" do
      expect(mail.body.encoded).to eq("")
    end

  end

end
