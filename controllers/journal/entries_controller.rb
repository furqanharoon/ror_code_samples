class Journal::EntriesController < ApplicationController
  include ActionView::Helpers::TextHelper
  include ActionView::Helpers::NumberHelper
  include CarrierWave::MiniMagick

  layout 'with_sidebar', only: [:show]

  load_resource :journal, except: [:dead_animal, :unlocked]
  before_filter :authenticate_user!

  before_filter :find_entry, except: [:create, :unlocked, :dead_animal]

  authorize_resource :entry, class: 'Journal::Entry'

  def duplicate_and_cancel_entry
    if @entry
      authorize!(:update, @entry)
      new_entry = @journal.duplicate_and_cancel_entry!(@entry) if @entry.can_be_cancelled?

      respond_to do |format|
        format.json do
          if new_entry
            render json: { id: new_entry.id }
          else
            render json: { errors: [ I18n.t(:failed_cancellation, scope: 'journal.entry') ] }, status: :unprocessable_entity
          end
        end
        format.html do
          if new_entry
            redirect_to polymorphic_path([@entry.customer, @journal.owner]), notice: I18n.t(:cancelled, scope: 'journal.entry')
          else
            redirect_to polymorphic_path([@entry.customer, @journal.owner]), alert: I18n.t(:failed_cancellation, scope: 'journal.entry')
          end
        end
      end
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def create
    authorize!(:create, Journal::Entry)

    @show_template_help = true

    init_template_id = params[:initial_template_id]

    form_service = Journal::FormService.new(nil, {
      user:                current_user,
      location:            current_location,
      initial_template_id: init_template_id,
      customer_id:         params[:customer_id],
      appointment_id:      params[:appointment_id],
      quotation_id:        params[:quotation_id],
      journal_id:          @journal.id
    })

    if params[:quotation_id].present?
      @entry = form_service.create_new_entry_from_quotation!
    else
      @entry = form_service.create_new_entry!
    end

    @entry.open_for_editing(current_user)

    if @entry.errors.any?
      render json: { errors: @entry.errors.to_a }, status: :unprocessable_entity # 422 status code, Rails default for validation errors
    else
      render 'edit', layout: false
    end
  end

  def edit
    if @entry
      authorize!(:update, @entry)

      unless @entry.open_for_editing(current_user)
        render status: 403, text: "Ändras redan av #{@entry.opened_for_editing_by.name} sedan #{l(@entry.opened_for_editing_at, format: :only_time)}. Öppnas för ändringar på nytt när #{@entry.opened_for_editing_by.first_name} är klar eller #{l(@entry.opened_for_editing_at + 30.minutes, format: :only_time)}."
        return
      end
      @show_template_help = true if params[:show_template_help]
      render layout: false
    else
      render status: 403, text: entry_missing
    end
  end

  def show
    if @entry
      authorize!(:read, @entry)

      if request.xhr?
        render partial: 'show', locals: { journal_entry: @entry, edit: true, pdf: false }
      else
        @customer = @entry.customer
        @owner = @entry.journal.owner

        respond_to do |format|
          format.html
          format.pdf do
            header_title, header_class, top = get_parameters_for_pdf

            render pdf: "#{@entry.initial_template.document_header} - #{@owner.name}", template: '/journal/entries/show_certificate_for_pdf',
                   header: {spacing: configatron.print.header_spacing, html: { template: 'templates/header_pdf',
                                     locals: { location: current_location, header_title: header_title, header_class: header_class } },
                            },
                   footer: { spacing: configatron.print.footer_spacing, html: { template: 'templates/footer_pdf' } },
                   show_as_html: params[:debug].present?,
                   layout: 'pdf_without_javascript.html'
          end
        end
      end
    else
      render status: 403, text: entry_missing
    end
  end

  def add_template
    if @entry
      authorize!(:update, @entry)

      form_service = Journal::FormService.new(@entry.form, {
        template_id: params[:template_id],
        position:    params[:position],
      })

      success, start_position, end_position, new_rows = form_service.add_template

      if success
        render json: {
          position: { start_position: start_position, end_position: end_position },
          billing_record_total_amount: billing_record_total_amount(new_rows),
          rows: new_rows.map do |row|
            render_to_string(partial: "journal/form_rows/form", locals: { row: row, form_disabled: false, buttons_disabled: false, show_price_range: false })
          end
        }
      else
        errors = new_rows.flat_map { |row| row.errors.full_messages }

        render json: { errors: [ errors ] }, status: :unprocessable_entity
      end
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def delete_row
    if @entry
      authorize!(:destroy, @entry)
      form_service = Journal::FormService.new(@entry.form, {
        row_id:  params[:row_id],
      })

      success, errors, deleted_row = form_service.delete_row

      if success
        render json: {
          billing_record_total_amount: billing_record_total_amount([deleted_row]),
          deleted: deleted_row.destroyed?
        }
      else
        render json: { errors: errors }, status: :unprocessable_entity
      end
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def move_row
    if @entry
      authorize!(:update, @entry)
      form_service = Journal::FormService.new(@entry.form, {
        row_id:   params[:row_id],
        position: params[:position],
      })

      success = form_service.move_row

      if success
        render json: { success: success }
      else
        render json: { success: success }, status: :unprocessable_entity
      end
    else
      render json: { success: false, errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def update
    if @entry
      authorize!(:update, @entry)

      if @entry.update(params[:journal_entry])
        render json: {}
      else
        render json: { errors: @entry.errors }, status: :unprocessable_entity
      end
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def update_appointment
    if @entry
      authorize!(:update, @entry)

      appointment_updated = true

      begin
        @entry.update(params["journal_entry"])
      rescue ActiveRecord::RecordInvalid => e
        appointment_updated = false
        logger.warn "#{self.class.name}##{action_name}: #{e.message}"
      end

      if appointment_updated
        render json: {}
      else
        @entry.reload
        render json: {
          errors: [ I18n.t(:appointment_update_failed, scope: 'journal.entry') ],
          appointment_id: @entry.appointment.id,
          appointment_title: @entry.appointment.to_s,
        }, status: :unprocessable_entity
      end
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def update_row
    if @entry
      authorize!(:update, @entry)
      form_service = Journal::FormService.new(@entry.form, {
        row_id:         params[:journal_entry][:row_attributes].first.delete(:id),
        position:       params[:position],
        kind:           params[:journal_entry][:row_attributes].first[:kind],
        row_attributes: params[:journal_entry][:row_attributes].first,
      })

      success, errors, row = form_service.create_or_update_row

      if success
        render json: {
          billing_record_total_amount: billing_record_total_amount([row]),
          row: row_data_helper(row)
        }
      else
        render json: { errors: errors }, status: :unprocessable_entity
      end
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def lock
    if @entry
      authorize!(:update, @entry)

      unless @entry.locked?
        form_service = Journal::FormService.new(@entry.form, {
          user: current_user,
        })
        success, errors = form_service.lock_entry
      end

      if success or @entry.locked?
        render json: {
          billing_record_removed: @entry.billing_record.blank?,
          lethal_modal_path: lethal_modal_journal_entry_path(@journal, @entry),
          show_lethal_modal: @entry.lethal_items?,
          create_invitation_modal_path: create_invitation_modal_journal_entry_path(@journal, @entry),
          show_create_invitation_modal: @entry.create_invitation_items?,
          status: @entry.traffic_light_color
        }
      else
        render json: { errors: errors }, status: :unprocessable_entity
      end
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def unlocked
    authorize!(:view_unfinished_entries, Journal::Entry)
    @entries = Journal::Entry.where(location_id: current_location, locked: false).includes(:customer, :location, :user, journal: :owner)
  end

  def destroy_recently_added_rows
    if @entry
      authorize!(:update, @entry)
      form_service = Journal::FormService.new(@entry.form, {
        start_position: params[:start_position],
        end_position:   params[:end_position],
      })

      form_service.remove_rows_in_range!

      head :ok
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def destroy
    if @entry
      authorize!(:destroy, @entry)

      if @entry.deletable?
        mandatory_rows_hustled = if @entry.form.rows.any?(&:mandatory)
          form_service = Journal::FormService.new(@entry.form, {
            start_position: 1,
            end_position:   @entry.form.rows.maximum(:position),
          })

          success, errors, row = form_service.remove_rows_in_range!
          success
        else
          true
        end

        @entry.destroy if mandatory_rows_hustled
      end

      render json: { deleted: @entry.destroyed? }
    else
      render json: { deleted: true }
    end
  end

  def close_for_editing
    if @entry
      authorize!(:update, @entry)
      @entry.close_for_editing
      head :ok
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def change_appointment_modal
    if @entry
      authorize!(:update, @entry)

      @owner = @entry.journal.owner
      customer = @entry.customer

      @appointments_for_owner = @owner.appointments
      @appointments_for_customer = customer.appointments.reject { |a| a.animals.any? } + customer.appointments.reject { |a| a.herds.any? } + customer.appointments.reject { |a| a.animal_groups.any? }

      @appointments = (@appointments_for_owner + @appointments_for_customer).uniq.select { |a| ["new", "arrived", "started"].include? a.status }

      render layout: false
    else
      render json: { errors: [ entry_missing ] }, status: :unprocessable_entity
    end
  end

  def lethal_modal
    authorize!(:read, @entry)

    @customer = @entry.customer
    @owner = @entry.journal.owner

    render layout: false
  end

  def create_invitation_modal
    authorize!(:read, @entry)

    @customer = @entry.customer
    @owner = @entry.journal.owner
    @invitation = @customer.appointment_invitations.new
    @invitation.resource = @entry.journal.owner
    @invitation.visit_reason = @entry.appointment.visit_reasons.first if @entry.appointment
    @text_tempaltes_for_invitation = TextTemplate.for_invitations.for_animal_kind(@owner.kind).all

    render layout: false
  end

  def dead_animal
    journal = Journal.find(params[:id])
    authorize!(:read, Journal::Entry)
    render json: { dead_animal: journal.dead_animal? }
  end

  private

  def row_data_helper(r)
    item_row = r.kind_of?(Journal::FormRow::ItemRow)

    {
      id: r.id,
      placeholder_id: r.placeholder_id,
      total_amount: item_row ? number_with_precision(r.amount_including_factors) || 0 : '',
      unit_amount: item_row ? number_with_precision(r.unit_price) || 0 : '',
      toolbox: render_to_string( partial: 'journal/form_rows/toolbox', locals: { row: r } ),
      responsible_user: r.responsible ? r.responsible.name_and_abbreviated_title : ''
    }
  end

  def find_entry
    begin
      @entry = @journal.entries.find(params[:id])
    rescue ActiveRecord::RecordNotFound => e
      @entry = nil
      logger.warn "#{self.class.name}##{action_name}: #{e.message}"
    end
  end

  def entry_missing
    I18n.t(:missing, scope: 'journal.entry')
  end

  # Only recalculate this amount if an item row was added/updated/removed
  def billing_record_total_amount(rows)
    rows.any? { |row| row.respond_to?(:billing_record_row) } ? number_to_currency(@entry.billing_record.try(&:total_amount)) : ''
  end

  def get_parameters_for_pdf
    header_title = simple_format(@entry.initial_template.try(:document_header)) || 'Intyg'
    header_class = 'header_title'
    top = 50

    if header_title.length > 20 + 5
      # Cut words longer than 35 chars at 30 chars (unless compound). Remove "<p></p>" prior.
      if header_title.length > 35 + 5
        header_title = header_title[3..-5].split().map do |word|
          word.include?('-') || word.length <= 35 ? word : word.scan(/.{30}|.+/).join("<br/>-")
        end.join(' ')
      end

      # Super ugly workaround for multi-lined titles getting clipped off at the top. Max
      # length for header is 64.
      # See https://code.google.com/p/wkhtmltopdf/issues/detail?id=175 or
      # https://code.google.com/p/wkhtmltopdf/issues/detail?id=522
      # Note that these spacings are based on lorem ipsum type words
      case
        when header_title.length < 30 then top = 45
        when header_title.length < 65 then top = 53
      end

      header_title = "<p>#{header_title}</p>"
      header_class += '_long'
    end

    [header_title, header_class, top]
  end

end
