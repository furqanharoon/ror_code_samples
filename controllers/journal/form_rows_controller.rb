class Journal::FormRowsController < ApplicationController
  include ActionView::Helpers::NumberHelper
  before_filter :authenticate_user!

  # duplicate a form row and inserts it after the original
  def duplicate
    @entry = Journal::Entry.find(params[:entry_id])
    authorize!(:update, @entry)

    form_service = Journal::FormService.new(@entry.form, {
      row_id: params[:id],
    })

    success, new_row = form_service.duplicate_row

    respond_to do |format|
      format.json do
        if success
          render json: {
            id: new_row.id,
            billing_record_total_amount: billing_record_total_amount([new_row]),
            row: render_to_string(partial: "journal/form_rows/form", locals: { row: new_row, form_disabled: false, buttons_disabled: false, show_price_range: false }, :formats => [:html])
          }
        else
          render json: { errors: ["Det går inte att duplicera rader knutna till debiteringsrader eftersom debiteringsunderlaget är låst."] }, status: :unprocessable_entity
        end
      end
    end
  end

  def history
    @row = Journal::FormRow.with_deleted.find(params[:id])

    @entry = @row.form.entry
    @customer = @entry.customer
    @owner = @entry.journal.owner
    @history_rows = @row.row_history
  end

  def template_create_drug_row
    @template = Journal::FormTemplate.find(params[:template_id])
    authorize!(:update, @template)

    position = params[:journal_form_row_drug_row].delete(:position)
    params[:journal_form_row_drug_row].delete(:npl_pack_id)
    #params[:journal_form_row_drug_row][:validate_drug_delivery] = true
    params[:journal_form_row_drug_row][:do_not_generate_qualifications_attributes] = true

    form_service = Journal::FormService.new(@template.form, {
      position:       position,
      kind:           "drug",
      row_attributes: params[:journal_form_row_drug_row],
    })

    success, errors, row = form_service.create_or_update_row

    template_render_row(success, row)
  end

  def create_drug_row
    @entry = Journal::Entry.find(params[:entry_id])
    authorize!(:update, @entry)

    position = params[:journal_form_row_drug_row].delete(:position)
    params[:journal_form_row_drug_row].delete(:npl_pack_id)
    params[:journal_form_row_drug_row][:validate_drug_delivery] = true
    params[:journal_form_row_drug_row][:do_not_generate_qualifications_attributes] = true

    form_service = Journal::FormService.new(@entry.form, {
      position:       position,
      kind:           "drug",
      row_attributes: params[:journal_form_row_drug_row],
    })

    success, errors, row = form_service.create_or_update_row

    render_row(success, row)
  end

  def template_update_drug_row
    @template = Journal::FormTemplate.find(params[:template_id])
    authorize!(:update, @template)

    position = params[:journal_form_row_drug_row].delete(:position)
    #params[:journal_form_row_drug_row][:validate_drug_delivery] = true
    params[:journal_form_row_drug_row][:skip_already_paid_check] = true

    form_service = Journal::FormService.new(@template.form, {
      row_id:         params[:id],
      position:       position,
      kind:           "drug",
      row_attributes: params[:journal_form_row_drug_row],
    })

    success, errors, row = form_service.create_or_update_row

    template_render_row(success, row)
  end

  def update_drug_row
    @entry = Journal::Entry.find(params[:entry_id])
    authorize!(:update, @entry)

    position = params[:journal_form_row_drug_row].delete(:position)
    params[:journal_form_row_drug_row][:validate_drug_delivery] = true
    params[:journal_form_row_drug_row][:skip_already_paid_check] = true

    form_service = Journal::FormService.new(@entry.form, {
      row_id:         params[:id],
      position:       position,
      kind:           "drug",
      row_attributes: params[:journal_form_row_drug_row],
    })

    success, errors, row = form_service.create_or_update_row

    render_row(success, row)
  end

  def new_prescription
    entry = Journal::Entry.find(params[:entry_id])
    authorize!(:update, entry)

    form_service = Journal::FormService.new( entry.form,
      position:       params[:position],
      kind:           "prescription",
      row_attributes: {},
    )
    success, errors, row = form_service.create_or_update_row

    redirect_to new_send_vet_prescription_path(entry_id: entry.id, placeholder_id: row.placeholder_id, source_id: params[:source_id])
  end

  def placeholder_id
    row = Journal::FormRow.find(params[:id])
    authorize!(:read, row.form.entry)

    respond_to do |format|
      format.json { render json: { placeholder_id: row.placeholder_id } }
    end
  end

  def template_drug_administration_modal
    @template = Journal::FormTemplate.find(params[:template_id])
    authorize!(:update, @template)

    @drug_row = find_or_build_drug_row(params[:id], params[:position], @template.form)

    (2-@drug_row.qualifications.size).times do
      @drug_row.qualifications.build
    end

    render :drug_administration_modal, layout: false
  end

  def drug_administration_modal
    @entry = Journal::Entry.find(params[:entry_id])
    authorize!(:update, @entry)

    @drug_row = find_or_build_drug_row(params[:id], params[:position], @entry.form)

    (2-@drug_row.qualifications.size).times do
      @drug_row.qualifications.build
    end

    render layout: false
  end

  def responsible_modal
    @row = Journal::FormRow.find(params[:id])
    authorize!(:update, @row.form.entry)

    render layout: false
  end

  def item_description_modal
    @row = Journal::FormRow.find(params[:id])
    authorize!(:read, @row.form.entry)

    @item = @row.respond_to?(:item) ? @row.item : @row
    render layout: false
  end

  def multiple_choice_edit_modal
    render layout: false
  end

  private

  def billing_record_total_amount(rows)
    rows.any? { |row| row.respond_to?(:billing_record_row) } ? number_to_currency(@entry.billing_record.try(&:total_amount)) : ''
  end

  def template_render_row(success, row)
    if success
      render json: {
        partial: render_to_string( partial: "journal/form_rows/edit", locals: { row: row, form_disabled: false, buttons_disabled: false, show_price_range: false } )
      }
    else
      render json: { errors: row.errors }, status: 422
    end
  end

  def render_row(success, row)
    if success
      render json: {
        billing_record_total_amount: billing_record_total_amount([row]),
        partial: render_to_string( partial: "journal/form_rows/form", locals: { row: row, form_disabled: false, buttons_disabled: false, show_price_range: false } )
      }
    else
      render json: { errors: row.errors }, status: 422
    end
  end

  def find_or_build_drug_row(id, position, form)
    Journal::FormRow::DrugRow.where(id: id).first_or_initialize.tap do |row|
      row.position = position.to_i
      row.form = form
    end
  end
end
