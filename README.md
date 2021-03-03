Kappa resimulation algorithm
---

Here is an implementation of the resimulation algorithm for Kappa.
It generates a random counterfactual trace given a reference trace and
an intervention.

### How to install

In order to build this repository, you need to install the KaSim API:
`opam install kappa-library`. Then, just type `make test`.

### How to use

The resimulator is mostly intended to be used as an OCaml library whose interface
can be found at `lib/resimulation.mli`. However, a restricted subset of features
is currently available through the `bin/resimulate` executable that can be used as
follows:
```
resimulate TRACE_FILE -b RULE
```
resimulates the trace contained in the json file `TRACE_FILE`, blocking every instance
of rule `RULE`.

## How to run resimulation algo
Example
```
'KaSim' 'test.ka' '-var' 'VA' '10000' '-trace' 't.json' -seed 23952244
dune exec bin/resimulate.exe -- tests/t.json --block-instances b --stats tests/stats --silent

```
## Command to convert Kappa model to SBML
```
KaDE -i kappamodelname.ka --ode-backend SBML
```
