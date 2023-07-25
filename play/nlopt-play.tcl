source "lib/c.tcl"

set cc [c create]
$cc include <math.h>
$cc include <nlopt.h>
$cc include <stdlib.h>
$cc code {
    double myfunc(unsigned n, const double *x, double *grad, void *my_func_data) {
        printf("iteration: myfunc(%f) = %f\n", x[0], fabs(x[0] - 5));
        if (grad) {
            if (x[0] < 5) { grad[0] = -1; }
            else { grad[0] = 1; }
        }
        return fabs(x[0] - 5);
    }
}
$cc proc f {} void {
    /* double lb[2] = {0, 0}; */
    /* double ub[2] = {0.99999, 0.99999}; */
    nlopt_opt opt = nlopt_create(NLOPT_LN_COBYLA, 1);
    /* nlopt_set_lower_bounds(opt, lb); */
    /* nlopt_set_upper_bounds(opt, ub); */
    nlopt_set_min_objective(opt, myfunc, NULL);

    double x[1] = { 0.5 };  /* `*`some` `initial` `guess`*` */
    double minf; /* `*`the` `minimum` `objective` `value,` `upon` `return`*` */
    nlopt_set_ftol_abs(opt, 1e-10);
    int ret = nlopt_optimize(opt, x, &minf);
    if (ret < 0) {
        printf("nlopt failed! %d\n", ret);
    } else {
        printf("found minimum at f(%g) = %f\n", x[0], minf);
    }
}
$cc cflags -lnlopt
$cc compile

f
