class Journal::FormTemplatesController < ApplicationController
  before_filter :authenticate_user!
  before_filter :find_template, only: [:new_row_html, :update_row, :delete_row, :move_row, :update, :insert_rows_from_include_row, :publish, :preview, :preview_include_row, :destroy, :show]

  def index
    authorize!(:read, Journal::FormTemplate)
    fetch_templates(scope: :public_templates)
  end

  def new
    authorize!(:read, Journal::FormTemplate)
    @template = Journal::FormTemplate.new
  end

  def create
    authorize!(:create, Journal::FormTemplate)

    form_service = Journal::FormService.new(nil, {
      kind:                 params[:journal_form_template][:kind],
      category:             params[:journal_form_template][:category],
      name:                 params[:journal_form_template][:name],
      searchable:           params[:journal_form_template][:journal_searchable],
      create_invitation:    params[:journal_form_template][:create_invitation],
      keyword:              params[:journal_form_template][:keyword],
      description:          params[:journal_form_template][:description],
      all_animal_kinds:     params[:journal_form_template][:all_animal_kinds],
      animal_kind_ids:      params[:journal_form_template][:animal_kind_ids],
      all_visiting_reasons: params[:journal_form_template][:all_visiting_reasons],
      visiting_reason_ids:  params[:journal_form_template][:visiting_reason_ids],
      all_locations:        params[:journal_form_template][:all_locations],
      location_ids:         params[:journal_form_template][:location_ids],
      document_header:      params[:journal_form_template][:document_header],
      user:                 current_user
    })

    @template = form_service.create_new_template!

    unless @template.errors.any?
      set_edited_by_current_user
      flash.notice = "Mallen skapades."
      flash.notice += " Du måste publicera mallen för att den ska bli synlig." if not (@template.public? or @template.new_record?)

      redirect_to @template
    else
      render action: "new"
    end
  end

  def update
    authorize!(:update, @template)
    @template.set_edited_by(current_user) if @template.public?

    params[:journal_form_template].delete(:form_row_attributes) if params[:journal_form_template]

    if @template.update(params[:journal_form_template])
      if request.xhr?
        render json: { published: false }
      else
        redirect_to @template, notice: 'Mallen har uppdaterats.'
      end
    else
      if request.xhr?
        errors = @template.form.rows.flat_map { |row| row.errors.full_messages }.uniq
        errors << [@template.errors[:certificate]] if @template.errors[:certificate].present?
        render json: { errors: errors, published: false }, status: :unprocessable_entity # 422 status code, Rails default for validation errors
      else
        render action: "show"
      end
    end
  end

  def destroy
    authorize!(:destroy, @template)
    @template.destroy
    redirect_to journal_form_templates_path, notice: 'Mallen är borttagen'
  end

  def show
    authorize!(:read, @template)
    flash.notice = "Eftersom du ändrat i mallen måste du publicera den igen för att den ska bli synlig." if not @template.public? and flash.notice.nil?
  end

  #
  # Row API
  #

  def new_row_html
    row = Journal::FormRow.new_from_kind(params[:kind])

    render partial: "journal/form_rows/edit", locals: { row: row }
  end

  def update_row
    authorize!(:update, @template)
    set_edited_by_current_user

    # Manually set :mandatory to false since if unchecked the HTML it will not serialize it.
    row_attributes = params[:journal_form_template][:form_row_attributes].first
    unless row_attributes.has_key?(:mandatory)
      row_attributes[:mandatory] = false
    end

    form_service = Journal::FormService.new(@template.form, {
      row_id:         params[:journal_form_template][:form_row_attributes].first.delete(:id),
      position:       params[:position],
      kind:           params[:journal_form_template][:form_row_attributes].first[:kind],
      row_attributes: row_attributes,
    })

    success, errors, row = form_service.create_or_update_row

    if success
      render json: { row: {
        id: row.id,
        total_amount: row.kind_of?(Journal::FormRow::ItemRow) ? row.item_price_range_string : '',
        }
      }
    else
      render json: { errors: errors }, status: :unprocessable_entity
    end
  end

  def delete_row
    authorize!(:destroy, @template)
    form_service = Journal::FormService.new(@template.form, {
      row_id:  params[:row_id],
      non_paranoid_delete: true, # Really delete the row, no soft delete (hide) in form template editor
    })

    success, errors, deleted_row = form_service.delete_row

    if success
      render json: { deleted: true }
    else
      render json: { errors: errors }, status: :unprocessable_entity
    end
  end

  def move_row
    authorize!(:update, @template)
    form_service = Journal::FormService.new(@template.form, {
      row_id:   params[:row_id],
      position: params[:position],
    })

    success = form_service.move_row
    if success
      render json: { success: success }
    else
      render json: { success: success }, status: :unprocessable_entity
    end
  end

  def insert_rows_from_include_row
    authorize!(:update, @template)
    form_service = Journal::FormService.new(@template.form, {
      row_id:      params[:row_id],
      non_paranoid_delete: true, # Really delete the include row, no soft delete (hide) in form template editor
    })

    success, rows, errors = form_service.insert_rows_from_include_row

    if success
      render partial: "journal/form_rows/edit", collection: rows, as: :row
    else
      render json: { errors: errors }, status: :unprocessable_entity
    end
  end

  def preview
    authorize!(:read, @template)
    render partial: "journal/form_rows/form", collection: @template.rows_with_included_rows, as: :row, locals: { form_disabled: false, buttons_disabled: true, show_price_range: true }
  end

  def preview_include_row
    authorize!(:read, @template)
    render partial: "journal/form_rows/form", collection: @template.rows_with_included_rows, as: :row, locals: { form_disabled: true, buttons_disabled: false, show_price_range: true }
  end

  def publish
    authorize!(:update, @template)
    @template.publish!
    redirect_to @template, notice: 'Mallen är publicerad.'
  end

  def unpublished_forms
    authorize!(:read, Journal::FormTemplate)
    fetch_templates(scope: :unpublished)
  end

  def frequently_used
    authorize!(:create, Journal::Entry)
    respond_to do |format|
      format.json do
        animal_kind_id = params[:animal_kind_id]
        visit_reasons = params[:visit_reasons]
        visit_reasons = [] if visit_reasons.blank?
        data = unless animal_kind_id.blank?
          Journal::FormTemplate.
                 frequently_used_for(animal_kind_id).
                 for_location(current_location.id).
                 for_visit_reasons(visit_reasons).
                 public_templates.
                 where(kind: params[:kind]).
                 limit(5)
        else
          {}
        end

        render :json => data.map {|t| {name: t.name, id: t.id, description: t.description} }
      end
    end
  end

  def quotation_templates
    authorize!(:read, Journal::FormTemplate)

    respond_to do |format|
      format.json do
        animal_kind_id = params[:animal_kind_id]
        kinds = [params[:kind]]
        # Templates for animals/herds always include templates
        # for animals-and-herds, but not vice-versa.
        if params[:kind] == 'animal_journal' || params[:kind] == 'herd_journal'
          kinds << 'animal_and_herd_journal'
        end
        data = Journal::FormTemplate.active_templates(current_location.id, [animal_kind_id], kinds)

        render json: data.map {|t| { name: t.name, id: t.id } }
      end
    end
  end

  def for_journal
    # TODO move to index?

    animal_kind_id      = params[:animal_kind_id] || []
    visiting_reason_ids = params[:visiting_reason_ids].present? ? params[:visiting_reason_ids] : []
    kind                = [params[:kind]]
    new_entry           = params[:new_entry]

    kind << "animal_and_herd_journal" unless params[:kind] == "animal_certificate"

    category_template_or_partial = ['all']
    category_template_or_partial << (value_to_boolean(new_entry) ? 'template' : 'partial')

    templates = Journal::FormTemplate
      .send(:public_templates)
      .joins('LEFT OUTER JOIN journal_form_template_locations ls ON journal_form_templates.id = ls.form_template_id')
      .where('ls.location_id = ? OR all_locations = TRUE', current_location.id)
      .joins('LEFT OUTER JOIN journal_form_templates_animal_kinds aks ON journal_form_templates.id = aks.form_template_id')
      .where('aks.kind_id IN(?) OR all_animal_kinds = TRUE', animal_kind_id)
      .joins('LEFT OUTER JOIN journal_form_template_visit_reasons vrs ON journal_form_templates.id = vrs.form_template_id')
      .where('journal_form_templates.kind IN(?)', kind.reject(&:blank?))
      .where('journal_form_templates.category IN(?)', category_template_or_partial)
      .where('journal_form_templates.journal_searchable = TRUE')

    if visiting_reason_ids.any?
      templates = templates.where('vrs.visit_reason_id IN(?) OR all_visiting_reasons = TRUE', visiting_reason_ids)
    else
      templates = templates.where('all_visiting_reasons = TRUE')
    end

    templates = templates
      .order(:name)
      .uniq

    respond_to do |format|
      format.json do
        render json: templates.to_json(only: [:id, :name, :description])
      end
    end
  end

  private

  def value_to_boolean(value)
    ActiveRecord::ConnectionAdapters::Column.value_to_boolean(value)
  end

  def fetch_templates(options = {})
    all_templates = Journal::FormTemplate.includes(:locations, :animal_kinds, :visiting_reasons)
    scope = options.delete(:scope) || :all
    @templates = all_templates.for_journal_entries.send(scope)
    @herd_templates = all_templates.for_herd_journal_entries.send(scope)
    @animal_and_herd_templates = all_templates.for_animal_and_herd_journal_entries.send(scope)
    @certificate_templates = all_templates.for_certificates.send(scope)
  end

  def find_template
    @template = Journal::FormTemplate.find(params[:id])
  end

  def set_edited_by_current_user
    @template.set_edited_by(current_user) if @template.public?
  end
end
