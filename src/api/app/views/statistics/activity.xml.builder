

xml.activity do

  if @package

    xml.package(
      :name => @package.name,
      :project => @package.project.name,
      :activity => @package.activity
    )

  elsif @project

    xml.project(
      :name => @project.name,
      :activity => @project.activity
    )

  end

end

