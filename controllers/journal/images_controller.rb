class Journal::ImagesController < ApplicationController
  before_filter :authenticate_user!

  def create
    authorize!(:update, Journal::Entry)

    @image = Journal::Image.new(params[:journal_image])

    if @image.save
      render json: { id: @image.id }
    else
      render json: { errors: @image.errors.full_messages.uniq }, status: :unprocessable_entity # 422 status code, Rails default for validation errors
    end
  end

  def edit
    authorize!(:update, Journal::Entry)

    @image = Journal::Image.find(params[:id])
    @sketch = Journal::ImageSketch.find_by_id(params[:sketch_id])
    render layout: false
  end

  def update
    authorize!(:update, Journal::Entry)

    sketch = Journal::ImageSketch.new
    sketch.image_id = params[:id]
    sketch.attributes = params[:journal_image_sketch]
    if sketch.save
      render json: { sketch_id: sketch.id, sketch_image_url: sketch.file.normal.url, sketch_edit_url: edit_journal_image_path(sketch.image, sketch_id: sketch.id) }
    else
      render json: { errors: sketch.errors.full_messages.uniq }, status: :unprocessable_entity # 422 status code, Rails default for validation errors
    end
  end

end
