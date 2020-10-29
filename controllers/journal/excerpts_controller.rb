class Journal::ExcerptsController < ApplicationController
  #NOTE
  # Is not possible to include ActionView::Helpers::UrlHelper if you want to use polymorphic_path
  # include ActionView::Helpers::UrlHelper
  include Rails.application.routes.url_helpers

  layout 'with_sidebar'

  before_filter :authenticate_user!
  load_resource :journal

  def show
    authorize!(:read, Journal::Entry)

    @excerpt = @journal.excerpts.find(params[:id])

    @editable = false
    @filtered = true
    @journal_entries = @excerpt.to_journal_entries
    @owner, @customer = @journal.owner, @excerpt.customer
    @lab_samples_to_print = @excerpt.lab_samples

    respond_to do |format|
      format.html
      format.pdf do
        render pdf: @excerpt.description, template: 'journal/excerpts/show_for_pdf',
               header: {spacing: configatron.print.header_spacing, html: { template: 'templates/header_pdf',
                                 locals: {
                                   header_title: "Journalutdrag",
                                   sub_header: "Journal ##{@journal.id} - #{@journal.owner.name}, #{@journal.owner.kind.name.mb_chars.downcase}",
                                   location: current_location
                                  } } },
               footer: { spacing: configatron.print.footer_spacing, html: { template: 'templates/footer_pdf' } },
               show_as_html: params[:debug].present?,
               layout: 'pdf_without_javascript.html'
      end
    end
  end

  def create
    authorize!(:read, Journal::Entry)

    @excerpt = Journal::Excerpt.new(params[:journal_excerpt])
    @excerpt.user = current_user

    if @excerpt.save
      flash[:excerpt_created] = @excerpt.id
    else
      rows_with_errors = @excerpt.entries.map(&:form).flat_map(&:rows).reject(&:valid?).flatten
      row_messages = rows_with_errors.map { |row| row.errors.full_messages }

      error_message = (@excerpt.errors.full_messages + row_messages.uniq).join(', ')
      flash[:alert] = error_message
    end

    if @excerpt.referral_id.present?
      referral = Referral.find(@excerpt.referral_id)
      referral.update_attribute(:journal_excerpt_id, @excerpt.id)

      if rows_with_errors
        entries_with_errors = rows_with_errors.map { |r| r.form.entry }.uniq

        entry_paths = entries_with_errors.map do |entry|
          path = polymorphic_path([entry.customer, entry.journal.owner], edit_mode: true, anchor: "journal-entry-#{entry.id}")
          "<a href=\"#{path}\">#{entry.journal.owner.name}</a>"
        end

        flash[:alert] = (error_message + "<br>Journalutdraget kunde inte sparas på grund av ogiltiga rader i journalanteckningen. Ändra i dessa journalanteckningar: #{entry_paths.join(", ")}").html_safe
      end

      redirect_to edit_referral_path(referral)
    else
      redirect_to :back
    end
  end

  protected

  def controller
    nil
  end
end
