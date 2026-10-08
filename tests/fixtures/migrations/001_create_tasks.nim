import leaf/migrations

migration create_tasks:
  change:
    createTable tasks:
      string title, nullable = false
      boolean done, default = false
      timestamps()

    addIndex tasks, [title]
