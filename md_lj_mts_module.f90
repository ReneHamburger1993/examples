! md_lj_mts_module.f90
! Force routine for MD, LJ atoms, multiple timesteps
MODULE md_module

  USE, INTRINSIC :: iso_fortran_env, ONLY : error_unit

  IMPLICIT NONE
  PRIVATE

  ! Public routines
  PUBLIC :: introduction, conclusion, allocate_arrays, deallocate_arrays
  PUBLIC :: force, hessian, potential_lrc, pressure_lrc

  ! Public data
  INTEGER,                                PUBLIC :: n ! Number of atoms
  REAL,    DIMENSION(:,:),   ALLOCATABLE, PUBLIC :: r ! Positions (3,n)
  REAL,    DIMENSION(:,:),   ALLOCATABLE, PUBLIC :: v ! Velocities (3,n)
  REAL,    DIMENSION(:,:,:), ALLOCATABLE, PUBLIC :: f ! Forces for each shell (3,n,k_max) 

CONTAINS

  SUBROUTINE introduction ( output_unit )
    IMPLICIT NONE
    INTEGER, INTENT(in) :: output_unit ! Unit for standard output

    WRITE ( unit=output_unit, fmt='(a)' ) 'Lennard-Jones potential'
    WRITE ( unit=output_unit, fmt='(a)' ) 'Cut-and-shifted version for dynamics'
    WRITE ( unit=output_unit, fmt='(a)' ) 'Cut (but not shifted) version also calculated'
    WRITE ( unit=output_unit, fmt='(a)' ) 'Calculated in shells with switching functions'
    WRITE ( unit=output_unit, fmt='(a)' ) 'Diameter, sigma = 1'   
    WRITE ( unit=output_unit, fmt='(a)' ) 'Well depth, epsilon = 1'  

  END SUBROUTINE introduction

  SUBROUTINE conclusion ( output_unit )
    IMPLICIT NONE
    INTEGER, INTENT(in) :: output_unit ! Unit for standard output

    WRITE ( unit=output_unit, fmt='(a)') 'Program ends'

  END SUBROUTINE conclusion

  SUBROUTINE allocate_arrays ( r_cut )
    IMPLICIT NONE
    REAL, DIMENSION(:), INTENT(in)  :: r_cut  ! shell cutoff distances

    INTEGER :: k_max
    k_max = SIZE(r_cut)
    ALLOCATE ( r(3,n), v(3,n), f(3,n,k_max) )

  END SUBROUTINE allocate_arrays

  SUBROUTINE deallocate_arrays
    IMPLICIT NONE

    DEALLOCATE ( r, v, f )

  END SUBROUTINE deallocate_arrays

  SUBROUTINE force ( box, r_cut, lambda, k, pot, cut, vir, lap, overlap )
    IMPLICIT NONE
    REAL,               INTENT(in)  :: box     ! Box length
    REAL, DIMENSION(:), INTENT(in)  :: r_cut   ! Shell cutoff distances
    REAL,               INTENT(in)  :: lambda  ! Switch function healing length
    INTEGER,            INTENT(in)  :: k       ! Shell for this force evaluation
    REAL,               INTENT(out) :: pot     ! Cut-and-shifted total potential energy
    REAL,               INTENT(out) :: cut     ! Cut (but not shifted) total potential energy
    REAL,               INTENT(out) :: vir     ! Total virial
    REAL,               INTENT(out) :: lap     ! Total Laplacian
    LOGICAL,            INTENT(out) :: overlap ! Warning flag that there is an overlap

    ! Calculates forces in array f, and also pot, cut, vir etc
    ! If overlap is set to .true., the forces etc should not be used
    ! Only separations lying in specified shell are considered
    ! The contributions include a multiplicative switching function
    ! NB virial includes derivative of switching function, because it is used in the 
    ! calculation of forces: when we sum over k to get pressure, these extra terms cancel
    ! lap does not include terms of this kind because we only need to sum over k to
    ! get the total at the end of a long step, and the extra terms would all vanish

    ! All quantities are calculated in units where sigma = 1 and epsilon = 1
    ! Positions are assumed to be in these units as well

    INTEGER            :: i, j, k_max
    REAL               :: rij_sq, rij_mag, sr2, sr6, sr12, s, ds, x
    REAL               :: pot_lj, cut_lj, vir_lj, lap_lj, potij, cutij, virij, lapij, pot_cut
    REAL, DIMENSION(3) :: rij, fij
    REAL               :: rk, rkm, rk_sq, rkm_sq         ! r_cut(k), r_cut(k-1) and squared values
    REAL               :: rk_l, rkm_l, rk_l_sq, rkm_l_sq ! Same, but for r_cut(k)-lambda etc
    REAL, PARAMETER    :: sr2_overlap = 1.8              ! Overlap threshold

    ! Distances for switching function
    k_max = SIZE(r_cut)
    IF ( k < 1 .OR. k > k_max ) THEN
       WRITE ( unit=error_unit, fmt='(a,2i15)' ) 'k, k_max error', k, k_max
       STOP 'Error in force'
    END IF

    rk      = r_cut(k)
    rk_l    = rk-lambda
    rk_sq   = rk ** 2
    rk_l_sq = rk_l ** 2
    IF ( k == 1 ) THEN
       rkm   = 0.0
       rkm_l = 0.0
    ELSE
       rkm   = r_cut(k-1)
       rkm_l = rkm-lambda
    END IF
    rkm_sq   = rkm ** 2
    rkm_l_sq = rkm_l ** 2

    ! Calculate shift in potential at outermost cutoff
    sr2     = 1.0 / r_cut(k_max)**2
    sr6     = sr2 ** 3
    sr12    = sr6 ** 2
    pot_cut = 4.0* ( sr12 - sr6 ) ! NB we include numerical factor

    ! Initialize
    f(:,:,k) = 0.0
    pot      = 0.0
    cut      = 0.0
    vir      = 0.0
    lap      = 0.0
    overlap  = .FALSE.

    ! Double loop over atoms
    DO i = 1, n-1
       DO j = i+1, n

          rij(:) = r(:,i) - r(:,j)                     ! Separation vector
          rij(:) = rij(:) - ANINT ( rij(:)/box ) * box ! Periodic boundary conditions
          rij_sq = SUM ( rij**2 )                      ! Squared separation

          IF ( rij_sq <= rk_sq .AND. rij_sq >= rkm_l_sq ) THEN ! Test whether in shell

             sr2 = 1.0 / rij_sq
             IF ( sr2 > sr2_overlap ) overlap = .TRUE. ! Overlap detected

             sr6    = sr2 ** 3
             sr12   = sr6 ** 2
             cut_lj = 4.0 *  ( sr12 - sr6 )                ! LJ cut (but not shifted) potential function
             pot_lj = cut_lj - pot_cut                     ! LJ cut-and-shifted potential function
             vir_lj = 24.0 * ( 2.0*sr12 - sr6)             ! -rij_mag*derivative of pot_lj
             lap_lj = 24.0 * ( 22.0*sr12 - 5.0*sr6 ) * sr2 ! LJ pair Laplacian

             ! The following statements implement S(k,rij_mag) - S(k-1,rij_mag)
             ! It is assumed that r_cut(k-1) and r_cut(k) are at least lambda apart

             IF ( rij_sq < rkm_sq ) THEN               ! S(k,rij_mag)=1, S(k-1,rij_mag) varying
                rij_mag = SQRT ( rij_sq )              ! rij_mag lies between rkm-lambda and rkm
                x       = (rij_mag-rkm)/lambda         ! x lies between -1 and 0
                s       = 1.0 - (2.0*x+3.0)*x**2       ! 1 - S(k-1,rij_mag) lies between 0 and 1
                ds      = 6.0*(x+1.0)*x*rij_mag/lambda ! -rij_mag*derivative of (1-S(k-1,rij_mag))
                potij   = s * pot_lj                   ! Potential includes switching function
                virij   = s * vir_lj + ds * pot_lj     ! Virial also includes derivative
                cutij   = s * cut_lj                   ! Cut potential includes switching function
                lapij   = s * lap_lj                   ! Laplacian includes switching function

             ELSE IF ( rij_sq > rk_l_sq ) THEN ! S(k,rij_mag) varying, S(k-1,rij_mag)=0

                IF ( k == k_max ) THEN ! No switch at outermost cutoff
                   potij = pot_lj      ! Potential unchanged
                   virij = vir_lj      ! Virial unchanged
                   cutij = cut_lj      ! Cut potential unchanged
                   lapij = lap_lj      ! Laplacian unchanged

                ELSE
                   rij_mag = SQRT ( rij_sq )               ! rij_mag lies between rk-lambda and rk
                   x       = (rij_mag-rk)/lambda           ! x lies between -1 and 0
                   s       = (2.0*x+3.0)*x**2              ! S(k,rij_mag) lies between 1 and 0
                   ds      = -6.0*(x+1.0)*x*rij_mag/lambda ! -rij_mag*derivative of S(k,rij_mag)
                   potij   = s * pot_lj                    ! Potential includes switching function
                   virij   = s * vir_lj + ds * pot_lj      ! Virial also includes derivative
                   cutij   = s * cut_lj                    ! Cut potential includes switching function
                   lapij   = s * lap_lj                    ! Laplacian includes switching function
                END IF

             ELSE               ! S(k,rij_mag)=1, S(k-1,rij_mag)=0, rij_mag lies between rkm and rk-lambda
                potij = pot_lj  ! Potential unchanged
                virij = vir_lj  ! Virial unchanged
                cutij = cut_lj  ! Cut potential unchanged
                lapij = lap_lj  ! Laplacian unchanged
             END IF

             fij = rij * virij / rij_sq

             pot      = pot + potij
             vir      = vir + virij
             cut      = cut + cutij
             lap      = lap + lapij
             f(:,i,k) = f(:,i,k) + fij
             f(:,j,k) = f(:,j,k) - fij

          END IF ! End test whether in shell

       END DO ! End loop over pairs in this shell
    END DO

    ! Multiply virial by numerical factor
    vir = vir / 3.0

    ! Multiply Laplacian by two to account for ij and ji
    lap = lap * 2.0

  END SUBROUTINE force

  FUNCTION potential_lrc ( density, r_cut )
    IMPLICIT NONE
    REAL                :: potential_lrc ! Returns long-range energy/atom
    REAL,    INTENT(in) :: density       ! Number density N/V
    REAL,    INTENT(in) :: r_cut         ! Cutoff distance

    ! Calculates long-range correction for Lennard-Jones energy per atom
    ! density, r_cut, and the results, are in LJ units where sigma = 1, epsilon = 1

    REAL            :: sr3
    REAL, PARAMETER :: pi = 4.0 * ATAN(1.0)

    sr3        = 1.0 / r_cut**3
    potential_lrc = pi * ( (8.0/9.0)  * sr3**3  - (8.0/3.0)  * sr3 ) * density

  END FUNCTION potential_lrc

  FUNCTION pressure_lrc ( density, r_cut )
    IMPLICIT NONE
    REAL                :: pressure_lrc ! Returns long-range pressure
    REAL,    INTENT(in) :: density      ! Number density N/V
    REAL,    INTENT(in) :: r_cut        ! Cutoff distance

    ! Calculates long-range correction for Lennard-Jones pressure
    ! density, r_cut, and the results, are in LJ units where sigma = 1, epsilon = 1

    REAL            :: sr3
    REAL, PARAMETER :: pi = 4.0 * ATAN(1.0)

    sr3          = 1.0 / r_cut**3
    pressure_lrc = pi * ( (32.0/9.0) * sr3**3  - (16.0/3.0) * sr3 ) * density**2

  END FUNCTION pressure_lrc

  FUNCTION hessian ( box, r_cut ) RESULT ( hes )
    IMPLICIT NONE
    REAL             :: hes   ! Returns the total Hessian
    REAL, INTENT(in) :: box   ! Simulation box length
    REAL, INTENT(in) :: r_cut ! Potential cutoff distance

    ! Calculates Hessian function (for 1/N correction to config temp)
    ! This routine is only needed in a constant-energy ensemble
    ! It is assumed that positions are in units where box = 1
    ! but the result is given in units where sigma = 1 and epsilon = 1
    ! It is assumed that forces for all shells have already been calculated in array f(3,n,:)
    ! These need to be summed over the last index to get the total fij between two atoms

    INTEGER            :: i, j
    REAL               :: r_cut_box, r_cut_box_sq, box_sq, rij_sq
    REAL               :: sr2, sr6, sr8, sr10, rf, ff, v1, v2
    REAL, DIMENSION(3) :: rij, fij

    r_cut_box    = r_cut / box
    r_cut_box_sq = r_cut_box ** 2
    box_sq       = box ** 2

    hes = 0.0

    DO i = 1, n - 1 ! Begin outer loop over atoms

       DO j = i + 1, n ! Begin inner loop over atoms

          rij(:) = r(:,i) - r(:,j)           ! Separation vector
          rij(:) = rij(:) - ANINT ( rij(:) ) ! Periodic boundary conditions in box=1 units
          rij_sq = SUM ( rij**2 )            ! Squared separation

          IF ( rij_sq < r_cut_box_sq ) THEN ! Check within cutoff

             rij_sq = rij_sq * box_sq ! Now in sigma=1 units
             rij(:) = rij(:) * box    ! Now in sigma=1 units

             fij(:) = SUM ( f(:,i,:) - f(:,j,:), dim=2 ) ! Difference in forces

             ff   = DOT_PRODUCT(fij,fij)
             rf   = DOT_PRODUCT(rij,fij)
             sr2  = 1.0 / rij_sq
             sr6  = sr2 ** 3
             sr8  = sr6 * sr2
             sr10 = sr8 * sr2
             v1   = 24.0 * ( 1.0 - 2.0 * sr6 ) * sr8
             v2   = 96.0 * ( 7.0 * sr6 - 2.0 ) * sr10
             hes  = hes + v1 * ff + v2 * rf**2

          END IF ! End check within cutoff

       END DO ! End inner loop over atoms

    END DO ! End outer loop over atoms

  END FUNCTION hessian

END MODULE md_module
