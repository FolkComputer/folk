typedef struct {
  int verbose;
  int max_it;
  double init_lambda;
  double up_factor;
  double down_factor;
  double target_derr;
  int final_it;
  double final_err;
  double final_derr;
} LMstat;

void levmarq_init(LMstat *lmstat);

int levmarq(int npar, double *par, int ny, double *y, double *dysq,
	    double (*func)(double *, int, void *),
	    void (*grad)(double *, double *, int, void *),
	    void *fdata, LMstat *lmstat);

double error_func(double *par, int ny, double *y, double *dysq,
		  double (*func)(double *, int, void *), void *fdata);

void solve_axb_cholesky(int n, double l[n][n], double x[n], double b[n]);

int cholesky_decomp(int n, double l[n][n], double a[n][n]);
