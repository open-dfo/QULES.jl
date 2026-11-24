/* Declarations for loadlibrary in matlab_probe.m: the functions the +qules
 * package calls, as in build/qules.h, with the log callback as void * and the
 * log buffer as unsigned char * (uint8Ptr), matching +qules/private/qules_proto.m. */
#include <stddef.h>
#include <stdint.h>

void init_julia(int argc, char *argv[]);
int qules_version_major(void);
int qules_version_minor(void);
int qules_version_patch(void);
int qules_set_log_mode(int mode, void *callback, void *user_data);
size_t qules_log_read(unsigned char *buffer, size_t capacity);
int64_t qules_session_create(size_t n_dim, const double *x_start, size_t max_evals,
                             double delta0, double delta_min, double delta_max,
                             int verbose, int rotation);
int qules_session_ask(int64_t session_id, double *x_out);
int qules_session_tell(int64_t session_id, double f_value);
int qules_session_is_finished(int64_t session_id);
int qules_session_get_best(int64_t session_id, double *x_best_out, double *f_best_out,
                           size_t *evals_out, double *delta_out);
int qules_session_free(int64_t session_id);
