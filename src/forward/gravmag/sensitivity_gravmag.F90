
!========================================================================
!
!                          T o m o f a s t - x
!                        -----------------------
!
!           Authors: Vitaliy Ogarko, Jeremie Giraud, Roland Martin.
!
!               (c) 2021 The University of Western Australia.
!
! The full text of the license is available in file "LICENSE".
!
!========================================================================

!========================================================================================
! A class to calculate sensitivity values for gravity or magnetic field.
!
! Vitaliy Ogarko, UWA, CET, Australia.
!========================================================================================
module sensitivity_gravmag

  use global_typedefs
  use mpi_tools, only: exit_MPI
  use parameters_mag
  use parameters_grav
  use magnetic_field
  use gravity_field
  use grid
  use model
  use data_gravmag
  use sparse_matrix
  use vector
  use wavelet_transform
  use parallel_tools

  implicit none

  private

  type, public :: t_sensitivity_gravmag
    private

  contains
    private

    procedure, public, nopass :: calculate_sensitivity_kernel
    procedure, public, nopass :: predict_sensit_kernel_size

    procedure, private, nopass :: calculate_sensitivity
    procedure, private, nopass :: apply_column_weight

  end type t_sensitivity_gravmag

contains

!=============================================================================================
! Calculates the sensitivity kernel and adds it to a sparse matrix.
!=============================================================================================
subroutine calculate_sensitivity_kernel(par, grid, data, column_weight, sensit_matrix, myrank, nbproc)
  class(t_parameters_base), intent(in) :: par
  type(t_grid), intent(in) :: grid
  type(t_data), intent(in) :: data
  real(kind=CUSTOM_REAL), intent(in) :: column_weight(:)
  integer, intent(in) :: myrank, nbproc

  ! Sensitivity matrix.
  type(t_sparse_matrix), intent(inout) :: sensit_matrix

  integer :: nnz
  logical :: STORE_KERNEL

  STORE_KERNEL = .true.

  call calculate_sensitivity(par, grid, data, column_weight, sensit_matrix, &
                             STORE_KERNEL, nnz, myrank, nbproc)

end subroutine calculate_sensitivity_kernel

!==================================================================================================
! Calculates the compressed sensitivity kernel size.
!==================================================================================================
function predict_sensit_kernel_size(par, grid, data, column_weight, myrank, nbproc) result (nnz)
  class(t_parameters_base), intent(in) :: par
  type(t_grid), intent(in) :: grid
  type(t_data), intent(in) :: data
  real(kind=CUSTOM_REAL), intent(in) :: column_weight(:)
  integer, intent(in) :: myrank, nbproc

  integer :: nnz

  type(t_sparse_matrix) :: dummy_matrix
  logical :: STORE_KERNEL

  STORE_KERNEL = .false.

  call calculate_sensitivity(par, grid, data, column_weight, dummy_matrix, &
                             STORE_KERNEL, nnz, myrank, nbproc)

end function predict_sensit_kernel_size

!=============================================================================================
! Calculates the sensitivity kernel / or predicts its size without storing the kernel,
! depending on the flag STORE_KERNEL.
!=============================================================================================
subroutine calculate_sensitivity(par, grid, data, column_weight, sensit_matrix, &
                                 STORE_KERNEL, nnz_local, myrank, nbproc)
  class(t_parameters_base), intent(in) :: par
  type(t_grid), intent(in) :: grid
  type(t_data), intent(in) :: data
  real(kind=CUSTOM_REAL), intent(in) :: column_weight(:)
  logical, intent(in) :: STORE_KERNEL
  integer, intent(in) :: myrank, nbproc

  ! The number of non-zero elements in the compressed sensitivity kernel on current CPU.
  integer, intent(out) :: nnz_local

  ! Sensitivity matrix.
  type(t_sparse_matrix), intent(inout) :: sensit_matrix

  type(t_magnetic_field) :: mag_field
  integer :: i, p, ierr
  real(kind=CUSTOM_REAL) :: comp_rate
  integer :: nsmaller, nelements_total
  type(t_parallel_tools) :: pt
  integer :: problem_type
  integer :: nnz_line
  real(kind=CUSTOM_REAL) :: nnz_total_dbl

  ! Sensitivity matrix row.
  real(kind=CUSTOM_REAL), allocatable :: sensit_line(:)
  real(kind=CUSTOM_REAL), allocatable :: sensit_line2(:)
  real(kind=CUSTOM_REAL), allocatable :: sensit_line3(:)
  real(kind=CUSTOM_REAL), allocatable :: sensit_line_full(:)

  allocate(sensit_line(par%nelements), source=0._CUSTOM_REAL, stat=ierr)
  if (ierr /= 0) call exit_MPI("Dynamic memory allocation error in calculate_sensitivity!", myrank, ierr)

  allocate(sensit_line2(par%nelements), source=0._CUSTOM_REAL, stat=ierr)
  if (ierr /= 0) call exit_MPI("Dynamic memory allocation error in calculate_sensitivity!", myrank, ierr)

  allocate(sensit_line3(par%nelements), source=0._CUSTOM_REAL, stat=ierr)
  if (ierr /= 0) call exit_MPI("Dynamic memory allocation error in calculate_sensitivity!", myrank, ierr)

  if (par%compression_type > 0) then
    if (nbproc > 1) then
      ! Number of parameters on ranks smaller than current one.
      nsmaller = pt%get_nsmaller(par%nelements, myrank, nbproc)

      ! Total number of elements.
      nelements_total = par%nx * par%ny * par%nz

      allocate(sensit_line_full(nelements_total), source=0._CUSTOM_REAL, stat=ierr)
      if (ierr /= 0) call exit_MPI("Dynamic memory allocation error in calculate_sensitivity!", myrank, ierr)
    endif
  endif

  select type(par)
  class is (t_parameters_grav)
    if (myrank == 0) print *, 'Calculating GRAVITY sensitivity kernel...'
    problem_type = 1

  class is (t_parameters_mag)
    if (myrank == 0) print *, 'Calculating MAGNETIC sensitivity kernel...'
    problem_type = 2

    ! Precompute common magnetic parameters.
    call mag_field%initialize(par%mi, par%md, par%fi, par%fd, par%theta, par%intensity)
  end select

  !--------------------------------------------------------------------------------------------
  ! Calculating sensitivity and adding to the sparse matrix / or calculating nnz for current CPU.
  nnz_local = 0

  ! Loop on all the data lines.
  do i = 1, par%ndata
    if (problem_type == 1) then
    ! Gravity problem.
      call graviprism_full(par%nelements, par%ncomponents, grid, data%X(i), data%Y(i), data%Z(i), &
                           sensit_line3, sensit_line2, sensit_line, myrank)
    else if (problem_type == 2) then
    ! Magnetic problem.
      call mag_field%magprism(par%nelements, i, grid, data%X, data%Y, data%Z, sensit_line)
    endif

    ! Applying the depth weight.
    call apply_column_weight(par%nelements, sensit_line, column_weight)

    if (par%compression_type > 0) then
    ! Wavelet compression.
      if (nbproc > 1) then
      ! Parallel wavelet copression.
        call pt%get_full_array(sensit_line, par%nelements, sensit_line_full, .true., myrank, nbproc)
        call Haar3D(sensit_line_full, par%nx, par%ny, par%nz, myrank, nbproc)

        ! Extract the local sensitivity part.
        sensit_line = sensit_line_full(nsmaller + 1 : nsmaller + par%nelements)
      else
      ! Serial.
        call Haar3D(sensit_line, par%nx, par%ny, par%nz, myrank, nbproc)
      endif

      ! Set values below the threshold to zero.
      do p = 1, par%nelements
        if (abs(sensit_line(p)) < par%wavelet_threshold) then
          sensit_line(p) = 0.d0
        endif
      enddo
    endif

    if (STORE_KERNEL) then
    ! Adding the sensitivity kernel the a sparse matrix.

      ! Sanity check: check if we have enough space in the matrix for new elemements.
      nnz_line = count(sensit_line /= 0.d0)
      if (sensit_matrix%get_number_elements() + nnz_line > sensit_matrix%get_nnz()) then
        call exit_MPI("The matrix size is too small, exiting!", myrank, ierr)
      endif

      call sensit_matrix%new_row(myrank)

      do p = 1, par%nelements
        ! Adding the Z-component only.
        call sensit_matrix%add(sensit_line(p), p, myrank)
      enddo
    endif

    ! The sensitivity kernel size.
    nnz_local = nnz_local + count(sensit_line /= 0.d0)

    ! Printing the progress.
    if (mod(i, int(0.1d0 * par%ndata)) == 0) then
      if (myrank == 0) print *, 'Percents completed: ', (i / int(0.1d0 * par%ndata)) * 10 ! Approximate percents.
    endif

  enddo ! data loop

  ! Sanity check.
  if (nnz_local < 0) then
    call exit_MPI("Integer overflow in nnz_local! Increase the wavelet threshold or the number of CPUs.", myrank, nnz_local)
  endif

  if (STORE_KERNEL) then
    call sensit_matrix%finalize(par%nelements, myrank)
  endif

  ! Calculate the kernel compression rate.
  if (nbproc > 1) then
    call mpi_allreduce(dble(nnz_local), nnz_total_dbl, 1, CUSTOM_MPI_TYPE, MPI_SUM, MPI_COMM_WORLD, ierr)
    comp_rate = nnz_total_dbl / dble(nelements_total) / dble(par%ndata)
  else
    comp_rate = dble(nnz_local) / dble(par%nelements) / dble(par%ndata)
  endif

  if (STORE_KERNEL) then
    if (myrank == 0) print *, 'COMPRESSION RATE = ', comp_rate
  else
    if (myrank == 0) print *, 'COMPRESSION RATE (estim) = ', comp_rate
  endif

  deallocate(sensit_line)
  deallocate(sensit_line2)
  deallocate(sensit_line3)
  if (allocated(sensit_line_full)) deallocate(sensit_line_full)

  if (myrank == 0) print *, 'Finished calculating the sensitivity kernel.'

end subroutine calculate_sensitivity

!==========================================================================================================
! Applying the column weight to sensitivity line.
!==========================================================================================================
subroutine apply_column_weight(nelements, sensit_line, column_weight)
  integer, intent(in) :: nelements
  real(kind=CUSTOM_REAL), intent(in) :: column_weight(:)

  real(kind=CUSTOM_REAL), intent(inout) :: sensit_line(:)

  integer :: i

  do i = 1, nelements
    sensit_line(i) = sensit_line(i) * column_weight(i)
  enddo

end subroutine apply_column_weight

end module sensitivity_gravmag
