/* 
 * MINPACK-1 Least Squares Fitting Library
 *
 * Test routines
 * 
 * These test routines provide examples for users to familiarize 
 * themselves with the mpfit library.  They also provide a baseline
 * test data set for users to be sure that the library is functioning
 * properly on their platform.
 *
 * By default, testmpfit is built by the distribution Makefile.
 *
 * To test the function of the mpfit library, 
 *   1. Build testmpfit   ("make testmpfit")
 *   2. Run testmpfit     ("./testmpfit")
 *   3. Compare results of your run with the distributed file testmpfit.log
 *
 * This file contains several test user functions:
 *   1. linfunc() linear fit function, y = f(x) = a - b*x
 *      - Driver is testlinfit()
 *   2. quadfunc() quadratic polynomial function, y = f(x) = a + b*x + c*x^2
 *      - Driver is testquadfit() - all parameters free
 *      - Driver is testquadfix() - linear parameter fixed
 *   3. gaussfunc() gaussian peak
 *      - Driver is testgaussfit() - all parameters free
 *      - Driver is testgaussfix() - constant & centroid fixed
 *           (this routine demonstrates in comments how to impose parameter limits)
 *   4. main() routine calls all five driver functions
 *
 * Copyright (C) 2003,2006,2009,2010, Craig Markwardt
 *
 */

/* Test routines for mpfit library
   $Id$
*/

#include "mpfit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* This is the private data structure which contains the data points
   and their uncertainties */
struct vars_struct {
  double *x;
  double *y;
  double *ey;
};

/* Simple routine to print the fit results */
void printresult(double *x, double *xact, mp_result *result) 
{
  int i;

  if ((x == 0) || (result == 0)) return;
  printf("  CHI-SQUARE = %f    (%d DOF)\n", 
	 result->bestnorm, result->nfunc-result->nfree);
  printf("        NPAR = %d\n", result->npar);
  printf("       NFREE = %d\n", result->nfree);
  printf("     NPEGGED = %d\n", result->npegged);
  printf("     NITER = %d\n", result->niter);
  printf("      NFEV = %d\n", result->nfev);
  printf("\n");
  if (xact) {
    for (i=0; i<result->npar; i++) {
      printf("  P[%d] = %f +/- %f     (ACTUAL %f)\n", 
	     i, x[i], result->xerror[i], xact[i]);
    }
  } else {
    for (i=0; i<result->npar; i++) {
      printf("  P[%d] = %f +/- %f\n", 
	     i, x[i], result->xerror[i]);
    }
  }
    
}

/* 
 * linear fit function
 *
 * m - number of data points
 * n - number of parameters (2)
 * p - array of fit parameters 
 * dy - array of residuals to be returned
 * vars - private data (struct vars_struct *)
 *
 * RETURNS: error code (0 = success)
 */
int linfunc(int m, int n, double *p, double *dy, double **dvec, void *vars)
{
  int i;
  struct vars_struct *v = (struct vars_struct *) vars;
  double *x, *y, *ey, f;

  x = v->x;
  y = v->y;
  ey = v->ey;

  for (i=0; i<m; i++) {
    f = p[0] + p[1]*x[i];     /* Linear fit function; note f = a + b*x */
    dy[i] = (y[i] - f)/ey[i];
  }

  return 0;
}

/* Test harness routine, which contains test data, invokes mpfit() */
int testlinfit()
{
  double x[] = {-1.7237128E+00,1.8712276E+00,-9.6608055E-01,
		-2.8394297E-01,1.3416969E+00,1.3757038E+00,
		-1.3703436E+00,4.2581975E-02,-1.4970151E-01,
		8.2065094E-01};
  double y[] = {1.9000429E-01,6.5807428E+00,1.4582725E+00,
		2.7270851E+00,5.5969253E+00,5.6249280E+00,
		0.787615,3.2599759E+00,2.9771762E+00,
		4.5936475E+00};
  double ey[10];
  /*      y = a - b*x    */
  /*              a    b */
  double p[2] = {1.0, 1.0};           /* Parameter initial conditions */
  double pactual[2] = {3.20, 1.78};   /* Actual values used to make data */
  double perror[2];                   /* Returned parameter errors */      
  int i;
  struct vars_struct v;
  int status;
  mp_result result;

  memset(&result,0,sizeof(result));       /* Zero results structure */
  result.xerror = perror;
  for (i=0; i<10; i++) ey[i] = 0.07;   /* Data errors */           

  v.x = x;
  v.y = y;
  v.ey = ey;

  /* Call fitting function for 10 data points and 2 parameters */
  status = mpfit(linfunc, 10, 2, p, 0, 0, (void *) &v, &result);

  printf("*** testlinfit status = %d\n", status);
  printresult(p, pactual, &result);

  return 0;
}

/* 
 * quadratic fit function
 *
 * m - number of data points
 * n - number of parameters (2)
 * p - array of fit parameters 
 * dy - array of residuals to be returned
 * vars - private data (struct vars_struct *)
 *
 * RETURNS: error code (0 = success)
 */
int quadfunc(int m, int n, double *p, double *dy, double **dvec, void *vars)
{
  int i;
  struct vars_struct *v = (struct vars_struct *) vars;
  double *x, *y, *ey;

  x = v->x;
  y = v->y;
  ey = v->ey;

  /* printf ("quadfunc %f %f %f\n", p[0], p[1], p[2]); */

  for (i=0; i<m; i++) {
    dy[i] = (y[i] - p[0] - p[1]*x[i] - p[2]*x[i]*x[i])/ey[i];
  }

  return 0;
}

/* Test harness routine, which contains test quadratic data, invokes
   mpfit() */
int testquadfit()
{
  double x[] = {-1.7237128E+00,1.8712276E+00,-9.6608055E-01,
		-2.8394297E-01,1.3416969E+00,1.3757038E+00,
		-1.3703436E+00,4.2581975E-02,-1.4970151E-01,
		8.2065094E-01};
  double y[] = {2.3095947E+01,2.6449392E+01,1.0204468E+01,
		5.40507,1.5787588E+01,1.6520903E+01,
		1.5971818E+01,4.7668524E+00,4.9337711E+00,
		8.7348375E+00};
  double ey[10];
  double p[] = {1.0, 1.0, 1.0};        /* Initial conditions */             
  double pactual[] = {4.7, 0.0, 6.2};  /* Actual values used to make data */
  double perror[3];		       /* Returned parameter errors */      
  int i;
  struct vars_struct v;
  int status;
  mp_result result;

  memset(&result,0,sizeof(result));          /* Zero results structure */
  result.xerror = perror;	                                      
  for (i=0; i<10; i++) ey[i] = 0.2;       /* Data errors */           

  v.x = x;
  v.y = y;
  v.ey = ey;

  /* Call fitting function for 10 data points and 3 parameters */
  status = mpfit(quadfunc, 10, 3, p, 0, 0, (void *) &v, &result);

  printf("*** testquadfit status = %d\n", status);
  printresult(p, pactual, &result);

  return 0;
}

/* Test harness routine, which contains test quadratic data;

   Example of how to fix a parameter
*/
int testquadfix()
{
  double x[] = {-1.7237128E+00,1.8712276E+00,-9.6608055E-01,
		-2.8394297E-01,1.3416969E+00,1.3757038E+00,
		-1.3703436E+00,4.2581975E-02,-1.4970151E-01,
		8.2065094E-01};
  double y[] = {2.3095947E+01,2.6449392E+01,1.0204468E+01,
		5.40507,1.5787588E+01,1.6520903E+01,
		1.5971818E+01,4.7668524E+00,4.9337711E+00,
		8.7348375E+00};

  double ey[10];
  double p[] = {1.0, 0.0, 1.0};        /* Initial conditions */             
  double pactual[] = {4.7, 0.0, 6.2};  /* Actual values used to make data */
  double perror[3];		       /* Returned parameter errors */      
  mp_par pars[3];                      /* Parameter constraints */          
  int i;
  struct vars_struct v;
  int status;
  mp_result result;

  memset(&result,0,sizeof(result));       /* Zero results structure */
  result.xerror = perror;

  memset(pars, 0, sizeof(pars));       /* Initialize constraint structure */
  pars[1].fixed = 1;                   /* Fix parameter 1 */

  for (i=0; i<10; i++) ey[i] = 0.2;

  v.x = x;
  v.y = y;
  v.ey = ey;

  /* Call fitting function for 10 data points and 3 parameters (1
     parameter fixed) */
  status = mpfit(quadfunc, 10, 3, p, pars, 0, (void *) &v, &result);

  printf("*** testquadfix status = %d\n", status);
  printresult(p, pactual, &result);

  return 0;
}

/* 
 * gaussian fit function
 *
 * m - number of data points
 * n - number of parameters (4)
 * p - array of fit parameters 
 *     p[0] = constant offset
 *     p[1] = peak y value
 *     p[2] = x centroid position
 *     p[3] = gaussian sigma width
 * dy - array of residuals to be returned
 * vars - private data (struct vars_struct *)
 *
 * RETURNS: error code (0 = success)
 */
int gaussfunc(int m, int n, double *p, double *dy, double **dvec, void *vars)
{
  int i;
  struct vars_struct *v = (struct vars_struct *) vars;
  double *x, *y, *ey;
  double xc, sig2;

  x = v->x;
  y = v->y;
  ey = v->ey;

  sig2 = p[3]*p[3];

  for (i=0; i<m; i++) {
    xc = x[i]-p[2];
    dy[i] = (y[i] - p[1]*exp(-0.5*xc*xc/sig2) - p[0])/ey[i];
  }

  return 0;
}

/* Test harness routine, which contains test gaussian-peak data */
int testgaussfit()
{
  double x[] = {-1.7237128E+00,1.8712276E+00,-9.6608055E-01,
		-2.8394297E-01,1.3416969E+00,1.3757038E+00,
		-1.3703436E+00,4.2581975E-02,-1.4970151E-01,
		8.2065094E-01};
  double y[] = {-4.4494256E-02,8.7324673E-01,7.4443483E-01,
		4.7631559E+00,1.7187297E-01,1.1639182E-01,
		1.5646480E+00,5.2322268E+00,4.2543168E+00,
		6.2792623E-01};
  double ey[10];
  double p[] = {0.0, 1.0, 1.0, 1.0};       /* Initial conditions */
  double pactual[] = {0.0, 4.70, 0.0, 0.5};/* Actual values used to make data*/
  double perror[4];			   /* Returned parameter errors */
  mp_par pars[4];			   /* Parameter constraints */         
  int i;
  struct vars_struct v;
  int status;
  mp_result result;

  memset(&result,0,sizeof(result));      /* Zero results structure */
  result.xerror = perror;

  memset(pars,0,sizeof(pars));        /* Initialize constraint structure */
  /* No constraints */

  for (i=0; i<10; i++) ey[i] = 0.5;

  v.x = x;
  v.y = y;
  v.ey = ey;

  /* Call fitting function for 10 data points and 4 parameters (no
     parameters fixed) */
  status = mpfit(gaussfunc, 10, 4, p, pars, 0, (void *) &v, &result);

  printf("*** testgaussfit status = %d\n", status);
  printresult(p, pactual, &result);

  return 0;
}


/* Test harness routine, which contains test gaussian-peak data 

   Example of fixing two parameter

   Commented example of how to put boundary constraints
*/
int testgaussfix()
{
  double x[] = {-1.7237128E+00,1.8712276E+00,-9.6608055E-01,
		-2.8394297E-01,1.3416969E+00,1.3757038E+00,
		-1.3703436E+00,4.2581975E-02,-1.4970151E-01,
		8.2065094E-01};
  double y[] = {-4.4494256E-02,8.7324673E-01,7.4443483E-01,
		4.7631559E+00,1.7187297E-01,1.1639182E-01,
		1.5646480E+00,5.2322268E+00,4.2543168E+00,
		6.2792623E-01};
  double ey[10];
  double p[] = {0.0, 1.0, 0.0, 0.1};       /* Initial conditions */            
  double pactual[] = {0.0, 4.70, 0.0, 0.5};/* Actual values used to make data*/
  double perror[4];			   /* Returned parameter errors */     
  mp_par pars[4];			   /* Parameter constraints */         
  int i;
  struct vars_struct v;
  int status;
  mp_result result;

  memset(&result,0,sizeof(result));  /* Zero results structure */
  result.xerror = perror;

  memset(pars,0,sizeof(pars));    /* Initialize constraint structure */
  pars[0].fixed = 1;              /* Fix parameters 0 and 2 */
  pars[2].fixed = 1;

  /* How to put limits on a parameter.  In this case, parameter 3 is
     limited to be between -0.3 and +0.2.
  pars[3].limited[0] = 0;    
  pars[3].limited[1] = 1;
  pars[3].limits[0] = -0.3;
  pars[3].limits[1] = +0.2;
  */

  for (i=0; i<10; i++) ey[i] = 0.5;

  v.x = x;
  v.y = y;
  v.ey = ey;

  /* Call fitting function for 10 data points and 4 parameters (2
     parameters fixed) */
  status = mpfit(gaussfunc, 10, 4, p, pars, 0, (void *) &v, &result);

  printf("*** testgaussfix status = %d\n", status);
  printresult(p, pactual, &result);

  return 0;
}


/* Main function which drives the whole thing */
int main(int argc, char *argv[])
{
  int i;
  int niter = 1;
  
  for (i=0; i<niter; i++) {
    testlinfit();
    testquadfit();
    testquadfix();
    testgaussfit();
    testgaussfix();
  }

  exit(0);
}
