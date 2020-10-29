class Journal::LibraryImageCategoriesController < ApplicationController
  before_filter :authenticate_user!

  def index
    authorize!(:read, Journal::LibraryImage::Category)
    @categories = Journal::LibraryImage::Category.order(:name).all

    respond_to do |format|
      format.html
      format.js { render layout: false }
    end
  end

  def new
    authorize!(:create, Journal::LibraryImage::Category)
    @library_image_category = Journal::LibraryImage::Category.new
  end

  def show
    @library_image_category = Journal::LibraryImage::Category.find(params[:id])
    authorize!(:read, @library_image_category)
  end

  def create
    authorize!(:create, Journal::LibraryImage::Category)
    @library_image_category = Journal::LibraryImage::Category.new(params[:journal_library_image_category])

    if @library_image_category.save
      redirect_to journal_library_image_categories_path, notice: 'Kategorin är tillagd.'
    else
      render action: "new"
    end
  end

  def update
    @library_image_category = Journal::LibraryImage::Category.find(params[:id])
    authorize!(:update, @library_image_category)

    @library_image_category.update(params[:journal_library_image_category])

    respond_to do |format|
      format.json do
        respond_with_bip(@library_image_category)
      end
    end
  end

  def destroy
    @library_image_category = Journal::LibraryImage::Category.find(params[:id])
    authorize!(:destroy, @library_image_category)
    @library_image_category.destroy

    redirect_to journal_library_images_url, notice: 'Kategorin har tagits bort.'
  end
end
