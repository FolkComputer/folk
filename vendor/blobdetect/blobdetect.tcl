namespace eval ::BlobDetect {
    set cc [c create]
    $cc cflags -I$::env(HOME)/apriltag $::env(HOME)/folk/vendor/blobdetect/hk.c
    $cc include <apriltag.h>
    $cc include <math.h>
    $cc include <assert.h>
    $cc code {
        int hoshen_kopelman(int **matrix, int m, int n);

        typedef struct {
            int id;

            // The center of the detection in image pixel coordinates.
            double c[2];

            // The corners of the tag in image pixel coordinates. These always
            // wrap counter-clock wise around the tag.
            // TL BL BR TR
            double p[4][2];

            int size;
        } detected_blob_t;

        zarray_t *blob_detector_detect(image_u8_t *im_orig, int threshold)
        {
            zarray_t *detections = zarray_create(sizeof(detected_blob_t*));

            // m = rows, n = columns
            int m = im_orig->height;
            int n = im_orig->width;
            int **matrix;
            matrix = (int **)malloc(m * sizeof(int *));
            for(int i = 0; i < m; i++)
                matrix[i] = (int *)malloc(n * sizeof(int));

            // for(int i = 0; i < rows; i++)
            //     memset(matrix[i], 0, cols * sizeof(int));
            
            // filter the raster into on or off
            for (int y = 0; y < im_orig->height; y++) {
                for (int x = 0; x < im_orig->width; x++) {
                    int i = y * im_orig->stride + x;
                    int v = im_orig->buf[i];

                    // threshold
                    if ((threshold >= 0 && v > threshold) || (threshold < 0 && v < -threshold)) {
                        v = 1;
                    } else {
                        v = 0;
                    }
                    matrix[y][x] = v;
                }
            }

            int clusters = hoshen_kopelman(matrix,m,n);
            // printf("clusters: %d\n", clusters);

            // initialize a structure 
            for (int i=0; i<clusters; i++) {
                detected_blob_t *det = calloc(1, sizeof(detected_blob_t));
                det->id = i;
                det->c[0] = 0;
                det->c[1] = 0;
                det->p[0][0] = 0;
                det->p[0][1] = 0;
                det->p[1][0] = 0;
                det->p[1][1] = 0;
                det->p[2][0] = 0;
                det->p[2][1] = 0;
                det->p[3][0] = 0;
                det->p[3][1] = 0;
                det->size = 0;
                zarray_add(detections, &det);
            }

            for (int i=0; i<m; i++) {
                for (int j=0; j<n; j++) {
                    // printf("%d ",matrix[i][j]); 
                    if (matrix[i][j]) {
                        detected_blob_t *det;
                        zarray_get(detections, matrix[i][j]-1, &det);
                        det->c[0] += j;
                        det->c[1] += i;
                        det->size += 1;
                    }
                }
                // printf("\n");
            }

            for (int i=0; i<clusters; i++) {
                detected_blob_t *det;
                zarray_get(detections, i, &det);
                det->id = i;
                det->c[0] = det->c[0] / det->size;
                det->c[1] = det->c[1] / det->size;
            }

            for (int i=0; i<m; i++)
                free(matrix[i]);
            free(matrix);

            return detections;
        }

        void blob_detection_destroy(detected_blob_t *det)
        {
            if (det == NULL)
                return;

            free(det);
        }

        void blob_detections_destroy(zarray_t *detections)
        {
            for (int i = 0; i < zarray_size(detections); i++) {
                detected_blob_t *det;
                zarray_get(detections, i, &det);

                blob_detection_destroy(det);
            }

            zarray_destroy(detections);
        }
    }
    defineImageType $cc

    $cc proc detect {image_t gray int threshold} Tcl_Obj* {
        assert(gray.components == 1);
        image_u8_t im = (image_u8_t) { .width = gray.width, .height = gray.height, .stride = gray.bytesPerRow, .buf = gray.data };

        zarray_t *detections = blob_detector_detect(&im, threshold);
        int detectionCount = zarray_size(detections);

        Tcl_Obj* detectionObjs[detectionCount];
        for (int i = 0; i < detectionCount; i++) {
            detected_blob_t *det;
            zarray_get(detections, i, &det);

            printf("detection %3d: id %-4d\n cx %f cy %f size %d\n", i, det->id, det->c[0], det->c[1], det->size);

            // int size = sqrt((det->p[0][0] - det->p[1][0])*(det->p[0][0] - det->p[1][0]) + (det->p[0][1] - det->p[1][1])*(det->p[0][1] - det->p[1][1]));
            int size = det->size;
            detectionObjs[i] = Tcl_ObjPrintf("id %d center {%f %f} corners {{%f %f} {%f %f} {%f %f} {%f %f}} size %d",
                                             det->id,
                                             det->c[0], det->c[1],
                                             det->p[0][0], det->p[0][1],
                                             det->p[1][0], det->p[1][1],
                                             det->p[2][0], det->p[2][1],
                                             det->p[3][0], det->p[3][1],
                                             size);
        }

        blob_detections_destroy(detections);
        
        Tcl_Obj* result = Tcl_NewListObj(detectionCount, detectionObjs);
        return result;
    }

    $cc compile
}
