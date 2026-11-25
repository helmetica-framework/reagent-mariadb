# mariadb

A helmetica reagent for MariaDB, wrapping `vshnmariadb` as its prima materia.

MariaDB services provided by helmetica: ordering one provisions a MariaDB instance with backups, network policies and credentials.

Documentation: https://docs.helmetica.io/reagent-mariadb/

## Development

```console
$ just test        # helm lint and the offline unit tests, no cluster needed
$ just touchstone  # end to end against a running athanor
$ just docs        # preview the docs
```
