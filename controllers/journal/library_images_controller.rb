class Journal::LibraryImagesController < ApplicationController
  before_filter :authenticate_user!

  def index
    authorize!(:read, Journal::LibraryImage)
    @library_images = Journal::LibraryImage.order(:name)

    respond_to do |format|
      format.html
      format.js { render layout: false }
    end
  end

  def new
    authorize!(:create, Journal::LibraryImage)
    @library_image = Journal::LibraryImage.new
  end

  def edit
    @library_image = Journal::LibraryImage.find(params[:id])
    authorize!(:update, @library_image)
  end

  def create
    authorize!(:create, Journal::LibraryImage)
    @library_image = Journal::LibraryImage.new(params[:journal_library_image])

    if @library_image.save
      redirect_to journal_library_images_path, notice: 'Bilden har lagts till i bildbiblioteket.'
    else
      render action: "new"
    end
  end

  def update
    @library_image = Journal::LibraryImage.find(params[:id])
    authorize!(:update, @library_image)
    if @library_image.update(params[:journal_library_image])
      redirect_to journal_library_images_path, notice: 'Bilden har ändrats.'
    else
      render action: "edit"
    end
  end

  def destroy
    @library_image = Journal::LibraryImage.find(params[:id])
    authorize!(:destroy, @library_image)
    @library_image.destroy

    redirect_to journal_library_images_url, notice: 'Bilden har tagits bort.'
  end
end
