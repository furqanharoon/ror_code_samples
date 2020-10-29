class Journal::CustomFormRowsController < ApplicationController
  before_filter :authenticate_user!
  load_resource :journal
  before_filter :find_entry
  authorize_resource :entry, class: 'Journal::Entry'

  layout false

  def new
    authorize!(:update, @entry)
    @add_custom = true
    @row = Journal::FormRow.new_from_kind(params[:row_kind]) if params[:row_kind]
  end

  def create
    authorize!(:update, @entry)
    @add_custom = true

    attrs = params[:journal_form_template][:form_row_attributes].first

    form_service = Journal::FormService.new( @entry.form,
      position:       params[:position],
      kind:           attrs.delete(:kind),
      row_attributes: attrs,
    )
    success, errors, @row = form_service.create_or_update_row

    if success
      respond_to do |format|
        format.json do
          render json: {
            positions: {
              start_position: params[:start_position].to_i,
              end_position:   params[:end_position].to_i + 1
            },
            row: render_to_string(partial: "journal/form_rows/form", locals: { row: @row, form_disabled: false, buttons_disabled: false, show_price_range: false }, formats: [:html])
          }
        end
      end
    else
      respond_to do |format|
        format.json do
          render json: { new_html: render_to_string('new', formats: [:html]) }
        end
      end
    end
  end

  def new_row_html
    row = Journal::FormRow.new_from_kind(params[:kind])

    render partial: "journal/form_rows/form", locals: { row: row, form_disabled: false, buttons_disabled: true, show_price_range: false }
  end

  def new_cmt_row_html
    form_service = Journal::FormService.new( @entry.form,
      position:       params[:position],
      kind:           params[:kind],
      row_attributes: {},
    )
    success, errors, row = form_service.create_or_update_row

    render partial: "journal/form_rows/form", locals: { row: row, form_disabled: false, buttons_disabled: false, show_price_range: false }
  end

  private

  def find_entry
    @entry = @journal.entries.find(params[:entry_id])
  end
end
