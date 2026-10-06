## Human-owned route configuration. The generator only updates generated/routes.nim.
import leaf
import ./generated/routes

proc applicationRoutes*(): seq[Route] =
  generatedRoutes()
