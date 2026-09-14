# Presidio

Both services are stateless: nothing under this directory is written at runtime.
It holds the two unit files and, later, any analyzer customisation. The analyzer image
reads optional configuration paths from the environment (`ANALYZER_CONF_FILE`,
`NLP_CONF_FILE`, `RECOGNIZER_REGISTRY_CONF_FILE`), so extra languages or custom
recognizers would be YAML files here, bind-mounted read-only and referenced with an
`Environment=` line in `llmgw-presidio-analyzer.container`. Not needed for phase 5.
