class Journal::DocumentsController < ApplicationController
  before_filter :authenticate_user!
  
  def create
    authorize!(:update, Journal::Entry)

    @document = Journal::Document.new(params[:journal_document])

    if @document.save
      render json: { id: @document.id, download_link: "#{@document.file.url}?download=true" }
    else
      render json: { errors: @document.errors.full_messages.uniq }, status: :unprocessable_entity # 422 status code, Rails default for validation errors
    end
  end
end
