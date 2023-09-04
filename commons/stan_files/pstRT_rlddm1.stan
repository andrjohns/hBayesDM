// Model 6 from Pedersen, Frank & Biele (2017) https://doi.org/10.3758/s13423-016-1199-y

functions{
  // Random number generator from Shahar et al. (2019) https://doi.org/10.1371/journal.pcbi.1006803
  vector wiener_rng(real a, real tau, real z, real d) {
    real dt;
    real sigma;
    real p;
    real y;
    real i;
    real aa;
    real ch;
    real rt;
    vector[2] ret;

    dt = .0001;
    sigma = 1;

    y = z * a;  // starting point
    p = .5 * (1 + ((d * sqrt(dt)) / sigma));
    i = 0;
    while (y < a && y > 0){
      aa = uniform_rng(0,1);
      if (aa <= p){
        y = y + sigma * sqrt(dt);
        i = i + 1;
      } else {
        y = y - sigma * sqrt(dt);
        i = i + 1;
      }
    }
    ch = (y <= 0) * 1 + 1;  // Upper boundary choice -> 1, lower boundary choice -> 2
    rt = i * dt + tau;

    ret[1] = ch;
    ret[2] = rt;
    return ret;
  }
}

data {
  int<lower=1> N;                         // Number of subjects
  int<lower=1> T;                         // Maximum number of trials
  array[N] int<lower=1> Tsubj;                  // Number of trials for each subject
  int<lower=1> n_cond;                    // Number of task conditions
  array[N, T] int<lower=-1, upper=n_cond> cond; // Task condition  (NA: -1)
  array[N, T] int<lower=-1, upper=2> choice;    // Response (NA: -1)
  array[N, T] real RT;                          // Response time
  array[N, T] real fd;                          // Feedback
  real initQ;                             // Initial Q value
  array[N] real minRT;                          // Minimum RT for each subject of the observed data
  real RTbound;                           // Lower bound or RT across all subjects (e.g., 0.1 second)
  array[n_cond] real prob;                      // Reward probability for each task condition (for posterior predictive check)
}

transformed data {
}

parameters {
  // Group-level raw parameters
  vector[4] mu_pr;
  vector<lower=0>[4] sigma;

  // Subject-level raw parameters (for Matt trick)
  vector[N] a_pr;         // Boundary separation
  vector[N] tau_pr;       // Non-decision time
  vector[N] v_pr;         // Drift rate scaling
  vector[N] alpha_pr;     // Learning rate
}

transformed parameters {
  // Transform subject-level raw parameters
  vector<lower=0>[N] a;
  vector<lower=RTbound, upper=max(minRT)>[N] tau;
  vector[N] v;
  vector<lower=0, upper=1>[N] alpha;

  for (i in 1:N) {
    a[i]     = exp(mu_pr[1] + sigma[1] * a_pr[i]);
    tau[i]   = Phi_approx(mu_pr[2] + sigma[2] * tau_pr[i]) * (minRT[i] - RTbound) + RTbound;
    alpha[i] = Phi_approx(mu_pr[4] + sigma[4] * alpha_pr[i]);
  }
  v = mu_pr[3] + sigma[3] * v_pr;
}

model {
  // Group-level raw parameters
  mu_pr ~ normal(0, 1);
  sigma ~ normal(0, 0.2);

  // Individual parameters
  a_pr     ~ normal(0, 1);
  tau_pr   ~ normal(0, 1);
  v_pr     ~ normal(0, 1);
  alpha_pr ~ normal(0, 1);

  // Subject loop
  for (i in 1:N) {
    // Declare variables
    int r;
    int s;
    real d;

    // Initialize Q-values
    matrix[n_cond, 2] Q;
    Q = rep_matrix(initQ, n_cond, 2);

    // Trial loop
    for (t in 1:Tsubj[i]) {
      // Save values to variables
      s = cond[i, t];
      r = choice[i, t];

      // Drift diffusion process
      d = (Q[s, 1] - Q[s, 2]) * v[i];  // Drift rate, Q[s, 1]: upper boundary option, Q[s, 2]: lower boundary option
      if (r == 1) {
        RT[i, t] ~ wiener(a[i], tau[i], 0.5, d);
      } else {
        RT[i, t] ~ wiener(a[i], tau[i], 0.5, -d);
      }

      // Update Q-value
      Q[s, r] += alpha[i] * (fd[i, t] - Q[s, r]);
    }
  }
}

generated quantities {
  // For group level parameters
  real<lower=0> mu_a;
  real<lower=RTbound, upper=max(minRT)> mu_tau;
  real mu_v;
  real<lower=0, upper=1> mu_alpha;

  // For log likelihood
  array[N] real log_lik;

  // For model regressors
  matrix[N, T] Q1;
  matrix[N, T] Q2;

  // For posterior predictive check (one-step method)
  matrix[N, T] choice_os;
  matrix[N, T] RT_os;
  vector[2]    tmp_os;

  // For posterior predictive check (simulation method)
  matrix[N, T] choice_sm;
  matrix[N, T] RT_sm;
  matrix[N, T] fd_sm;
  vector[2]    tmp_sm;
  real         rand;

  // Assign group-level parameter values
  mu_a      = exp(mu_pr[1]);
  mu_tau    = Phi_approx(mu_pr[2]) * (mean(minRT) - RTbound) + RTbound;
  mu_v      = mu_pr[3];
  mu_alpha  = Phi_approx(mu_pr[4]);

  // Set all posterior predictions to -1 (avoids NULL values)
  for (i in 1:N) {
    for (t in 1:T) {
      Q1[i, t]        = -1;
      Q2[i, t]        = -1;
      choice_os[i, t] = -1;
      RT_os[i, t]     = -1;
      choice_sm[i, t] = -1;
      RT_sm[i, t]     = -1;
      fd_sm[i, t]     = -1;
    }
  }

  { // local section, this saves time and space
    // Subject loop
    for (i in 1:N) {
      // Declare variables
      int r;
      int r_sm;
      int s;
      real d;
      real d_sm;

      // Initialize Q-values
      matrix[n_cond, 2] Q;
      matrix[n_cond, 2] Q_sm;
      Q    = rep_matrix(initQ, n_cond, 2);
      Q_sm = rep_matrix(initQ, n_cond, 2);

      // Initialized log likelihood
      log_lik[i] = 0;

      // Trial loop
      for (t in 1:Tsubj[i]) {
        // Save values to variables
        s = cond[i, t];
        r = choice[i, t];

        //////////// Posterior predictive check (one-step method) ////////////

        // Calculate Drift rate
        d = (Q[s, 1] - Q[s, 2]) * v[i];  // Q[s, 1]: upper boundary option, Q[s, 2]: lower boundary option

        // Drift diffusion process
        if (r == 1) {
          log_lik[i] += wiener_lpdf(RT[i, t] | a[i], tau[i], 0.5, d);
        } else {
          log_lik[i] += wiener_lpdf(RT[i, t] | a[i], tau[i], 0.5, -d);
        }

        tmp_os          = wiener_rng(a[i], tau[i], 0.5, d);
        choice_os[i, t] = tmp_os[1];
        RT_os[i, t]     = tmp_os[2];

        // Model regressors --> store values before being updated
        Q1[i, t] = Q[s, 1];
        Q2[i, t] = Q[s, 2];

        // Update Q-value
        Q[s, r] += alpha[i] * (fd[i, t] - Q[s, r]);

        //////////// Posterior predictive check (simulation method) ////////////

        // Calculate Drift rate
        d_sm = (Q_sm[s, 1] - Q_sm[s, 2]) * v[i];  // Q[s, 1]: upper boundary option, Q[s, 2]: lower boundary option

        // Drift diffusion process
        tmp_sm          = wiener_rng(a[i], tau[i], 0.5, d_sm);
        choice_sm[i, t] = tmp_sm[1];
        RT_sm[i, t]     = tmp_sm[2];

        // Determine feedback
        rand = uniform_rng(0, 1);
        if (choice_sm[i, t] == 1) {
          fd_sm[i, t] = rand <= prob[s];  // Upper boundary choice (correct)
        } else {
          fd_sm[i, t] = rand > prob[s];   // Lower boundary choice (incorrect)
        }

        // Update Q-value
        r_sm = (choice_sm[i, t] == 2) + 1;  // 'real' to 'int' conversion. 1 -> 1, 2 -> 2
        Q_sm[s, r_sm] += alpha[i] * (fd_sm[i, t] - Q_sm[s, r_sm]);
      }
    }
  }
}
