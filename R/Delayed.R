#' Delayed class that manages dependencies and computes when necessary
#'
#' @docType class
#'
#' @importFrom R6 R6Class
#' @importFrom uuid UUIDgenerate
#'
#' @rdname DelayedClass
#'
#' @export
#
Delayed <- R6Class(
    classname = "Delayed",
    cloneable = FALSE,
    portable = TRUE,
    class = TRUE,
    public = list(
      initialize = function(qexpr,
                            name = NULL,
                            sequential = FALSE) {
        private$.qexpr <- qexpr

        if (is.null(name)) {
          private$.name <- paste(deparse(UQE(qexpr)), collapse = "")
        } else {
          private$.name <- name
        }

        private$.sequential = sequential

        # TODO: this will break for nested expressions and also non-expressions
        private$.dependencies <- lapply(lang_tail(UQ(qexpr)),
                                        eval_bare,
                                        env = f_env(qexpr))

        private$.delayed_dependencies <- which(sapply(private$.dependencies,
                                                      inherits,
                                                      "Delayed"))
        private$.unresolved_dependencies <- private$.delayed_dependencies

        private$.uuid <- UUIDgenerate(use.time = TRUE)

        self$update_state

        invisible(self)
      },

      print = function() {
        print(sprintf("delayed(%s)", private$.name))
      },

      prepare_eval = function() {
        if (!self$ready) {
          stop("Task has unresolved dependencies: ",
               names(self$unresolved_dependencies))
        }

        undelay <- function(x) {
          if (inherits(x,"Delayed")) {
            return(x$value)
          } else if (inherits(x, "DistributedData")) {
            return(x$data)
          } else {
            return(x)
          }
        }

        args  <- lapply(self$dependencies, undelay)
        expr = UQE(self$expression)

        # this seems really dangerous
        mut_node_cdr(expr, as.pairlist(args))

        env <- f_env(self$expression)

        return(list(expr = expr, env = env))
      },

      prep_eval_distributed = function() {
        if (!self$ready) {
          stop("Task has unresolved dependencies: ",
               names(self$unresolved_dependencies)
              )
        }

        undelay <- function(x) {
          if (inherits(x, "Delayed")) {
            result_uuid <- x$job$result_uuid
            if (!is.null(result_uuid)) {
              return(distributed_from_uuid(x$job$result_uuid))
            } else {
              distributed_data(x$value)
            }
          } else if (inherits(x, "DistributedData")) {
            x
          } else {
            new_distributed <- distributed_data(x)
            # new_distributed$save()
            return(new_distributed)
          }
        }

        args  <- lapply(self$dependencies, undelay)
        fun <- lang_fn(self$expression)
        environment(fun) <- global_env()
        delayed_call <- list(fun = fun, args = args)
        return(delayed_call)
      },

      register_job = function(job) {
        private$.job = job
        private$.state = "running"
      },

      register_dependent = function(uuid) {
        private$.dependents = c(private$.dependents, uuid)
      },

      compute = function(...) {
        scheduler <- Scheduler$new(self, ...)
        value <- scheduler$compute()
        return(value)
      }
    ),

    active = list (
      name = function(name) {
        if (missing(name)) {
          return(private$.name)
        } else {
          private$.name = name
        }
      },

    expression = function() {
      return(private$.qexpr)
    },

    dependencies = function() {
      return(private$.dependencies)
    },

    dependents = function() {
      return(private$.dependents)
    },

    delayed_dependencies = function() {
      private$.dependencies[private$.delayed_dependencies]
    },

    unresolved_dependencies = function() {
      current_unresolved <- private$.unresolved_dependencies
      all_dependencies <- private$.dependencies
      newly_resolved <- sapply(all_dependencies[current_unresolved], `[[`,
                               "resolved")
      current_unresolved  <- current_unresolved[which(!newly_resolved)]
      private$.unresolved_dependencies <- current_unresolved
      return(all_dependencies[current_unresolved])
    },

    job = function() {
      return(private$.job)
    },

    value = function() {
      result <- private$.job$value
      
      if(inherits(result,"error")||inherits(result,"try-error")){
        private$.state <- "error"
      }
      return(result)
    },

    state = function() {
      return(private$.state)
    },

    update_state = function() {
      if ((private$.state == "waiting") &&
          length(self$unresolved_dependencies) == 0) {
        private$.state <- "ready"
      } else if ((private$.state=="running") && (private$.job$finished)) {
        private$.state <- "resolved"
      }

      return(private$.state)
    },

    ready = function() {
      return(self$state == "ready")
    },

    resolved = function() {
      return(self$state == "resolved")
    },

    uuid = function() {
      return(private$.uuid)
    },

    sequential = function(force) {
      if (!missing(force)) {
        private$.sequential = force
      }
      return(private$.sequential)
    }
  ),

  private = list(.name = NULL,
                 .qexpr = NULL,
                 .dependencies = list(),
                 .delayed_dependencies = c(),
                 .unresolved_dependencies = c(),
                 .dependants = list(),
                 .job = NULL,
                 .uuid = NULL,
                 .sequential = FALSE,
                 .state = "waiting",
                 .dependents = c()

                )
)

################################################################################

#' Generates Delayed Version of an Expression
#'
#' @param expr expression to delay
#' @param sequential if TRUE, never parallelize this task
#'
#' @rdname delayed
#'
#' @export
#
delayed <- function(expr, sequential = FALSE) {
  qexpr <- enquo(expr)
  Delayed$new(qexpr, sequential = sequential)
}

################################################################################

#' Generates Delayed Version of a Function
#'
#' @description A Delayed version of a function may be called to generate
#' Delayed objects
#'
#' @param fun function to delay
#'
#' @rdname delayed
#'
#' @export
#
delayed_fun <- function(fun, sequential = FALSE) {
  fun_name <- as.character(match.call()[[2]])
  delayed_f = function(...) {
    call <- match.call(fun,sys.call())
    call[[1]] <- as.name(fun_name)

    #make sure we have the right function in the env
    env <- new.env(parent=caller_env())
    assign(fun_name,fun, envir=env)
    pq <- as_quosure(call, env)
    Delayed$new(pq, sequential=sequential)
  }
}

################################################################################

#' Bundle Delayed Objects
#'
#' @description Bundling \code{Delayed} objects builds a single \code{Delayed}
#' object out of an arbitrary number of input \code{Delayed} objects.
#'
#' @param delayed_list A list of \code{Delayed} objects to bundle into a single
#' \code{Delayed} object
#'
#' @rdname bundle_delayed
#'
#' @export
#
bundle_delayed <- function(delayed_list) {
  delayed_bundle <- delayed_fun(bundle_args, sequential = TRUE)
  bundle <- do.call(delayed_bundle,delayed_list)
  bundle$name <- "bundle"
  return(bundle)
}

