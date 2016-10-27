! md_nvt_lj_le.f90
! MD, NVT ensemble, Lees-Edwards boundaries
PROGRAM md_nvt_lj_le

  USE, INTRINSIC :: iso_fortran_env, ONLY : input_unit, output_unit, error_unit, iostat_end, iostat_eor

  USE config_io_module, ONLY : read_cnf_atoms, write_cnf_atoms
  USE averages_module,  ONLY : time_stamp, run_begin, run_end, blk_begin, blk_end, blk_add
  USE md_module,        ONLY : introduction, conclusion, allocate_arrays, deallocate_arrays, &
       &                       force, r, v, f, n

  IMPLICIT NONE

  ! Takes in a configuration of atoms (positions, velocities)
  ! Cubic periodic boundary conditions, with Lees-Edwards shear
  ! Conducts molecular dynamics, SLLOD algorithm, with isokinetic thermostat
  ! Refs: Pan et al J Chem Phys 122 094114 (2005)

  ! Reads several variables and options from standard input using a namelist nml
  ! Leave namelist empty to accept supplied defaults

  ! Positions r are divided by box length after reading in and we assume mass=1 throughout
  ! However, input configuration, output configuration, most calculations, and all results 
  ! are given in simulation units defined by the model
  ! For example, for Lennard-Jones, sigma = 1, epsilon = 1

  ! Despite the program name, there is nothing here specific to Lennard-Jones
  ! The model is defined in md_module

  ! Most important variables
  REAL :: box         ! Box length
  REAL :: density     ! Density
  REAL :: dt          ! Time step
  REAL :: strain_rate ! Strain_rate (velocity gradient) dv_x/dr_y
  REAL :: strain      ! Strain (integrated velocity gradient) dr_x/dr_y
  REAL :: r_cut       ! Potential cutoff distance
  REAL :: pot         ! Total cut-and-shifted potential energy
  REAL :: cut         ! Total cut (but not shifted) potential energy
  REAL :: vir         ! Total virial
  REAL :: lap         ! Total Laplacian

  ! Quantities to be averaged
  REAL :: en_s ! Internal energy (cut-and-shifted) per atom
  REAL :: p_s  ! Pressure (cut-and-shifted)
  REAL :: en_f ! Internal energy (full, including LRC) per atom
  REAL :: p_f  ! Pressure (full, including LRC)
  REAL :: tk   ! Kinetic temperature
  REAL :: tc   ! Configurational temperature

  INTEGER :: blk, stp, nstep, nblock, ioerr
  LOGICAL :: overlap

  CHARACTER(len=4), PARAMETER :: cnf_prefix = 'cnf.'
  CHARACTER(len=3), PARAMETER :: inp_tag = 'inp', out_tag = 'out'
  CHARACTER(len=3)            :: sav_tag = 'sav' ! may be overwritten with block number

  NAMELIST /nml/ nblock, nstep, r_cut, dt, strain_rate

  WRITE ( unit=output_unit, fmt='(a)' ) 'md_nvt_lj_le'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Molecular dynamics, constant-NVT ensemble, Lees-Edwards'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Particle mass=1 throughout'
  CALL introduction ( output_unit )
  CALL time_stamp ( output_unit )

  ! Set sensible default run parameters for testing
  nblock      = 10
  nstep       = 1000
  r_cut       = 2.5
  dt          = 0.005
  strain_rate = 0.01

  READ ( unit=input_unit, nml=nml, iostat=ioerr )
  IF ( ioerr /= 0 ) THEN
     WRITE ( unit=error_unit, fmt='(a,i15)') 'Error reading namelist nml from standard input', ioerr
     IF ( ioerr == iostat_eor ) WRITE ( unit=error_unit, fmt='(a)') 'End of record'
     IF ( ioerr == iostat_end ) WRITE ( unit=error_unit, fmt='(a)') 'End of file'
     STOP 'Error in md_nvt_lj_le'
  END IF
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of blocks',          nblock
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of steps per block', nstep
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Potential cutoff distance', r_cut
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Time step',                 dt
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Strain rate',               strain_rate

  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, box ) ! First call just to get n and box
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of particles',   n
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Simulation box length', box
  density = REAL(n) / box**3
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Density', density

  CALL allocate_arrays ( box, r_cut )

  ! For simplicity we assume that input configuration has strain = 0
  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, box, r, v ) ! Second call gets r and v
  strain = 0.0

  r(:,:) = r(:,:) / box                       ! Convert positions to box units
  r(1,:) = r(1,:) - ANINT ( r(2,:) ) * strain ! Extra correction (box=1 units)
  r(:,:) = r(:,:) - ANINT ( r(:,:) )          ! Periodic boundaries (box=1 units)

  ! Initial forces, potential, etc plus overlap check
  CALL force ( box, r_cut, strain, pot, cut, vir, lap, overlap )
  IF ( overlap ) THEN
     WRITE ( unit=error_unit, fmt='(a)') 'Overlap in initial configuration'
     STOP 'Error in md_nvt_lj_le'
  END IF
  CALL calculate ( 'Initial values' )

  CALL run_begin ( [ CHARACTER(len=15) :: 'E/N (cut&shift)', 'P (cut&shift)', &
       &            'E/N (full)', 'P (full)', 'T (kin)', 'T (con)' ] )

  DO blk = 1, nblock ! Begin loop over blocks

     CALL blk_begin

     DO stp = 1, nstep ! Begin loop over steps

        ! Isokinetic SLLOD algorithm (Pan et al)

        CALL a_propagator  ( dt/2.0)
        CALL b1_propagator ( dt/2.0 )

        CALL force ( box, r_cut, strain, pot, cut, vir, lap, overlap )
        IF ( overlap ) THEN
           WRITE ( unit=error_unit, fmt='(a)') 'Overlap in configuration'
           STOP 'Error in md_nvt_lj_le'
        END IF

        CALL b2_propagator ( dt )
        CALL b1_propagator ( dt/2.0 )
        CALL a_propagator  ( dt/2.0 )

        ! Calculate all variables for this step
        CALL calculate ( )
        CALL blk_add ( [en_s,p_s,en_f,p_f,tk,tc] )

     END DO ! End loop over steps

     CALL blk_end ( blk, output_unit )
     IF ( nblock < 1000 ) WRITE(sav_tag,'(i3.3)') blk               ! number configuration by block
     CALL write_cnf_atoms ( cnf_prefix//sav_tag, n, box, r*box, v ) ! save configuration

  END DO ! End loop over blocks

  CALL run_end ( output_unit )

  CALL force ( box, r_cut, strain, pot, cut, vir, lap, overlap )
  IF ( overlap ) THEN ! should never happen
     WRITE ( unit=error_unit, fmt='(a)') 'Overlap in final configuration'
     STOP 'Error in md_nvt_lj_le'
  END IF
  CALL calculate ( 'Final values' )

  CALL write_cnf_atoms ( cnf_prefix//out_tag, n, box, r*box, v )
  CALL time_stamp ( output_unit )

  CALL deallocate_arrays
  CALL conclusion ( output_unit )

CONTAINS

  SUBROUTINE a_propagator ( t ) ! A propagator
    IMPLICIT NONE
    REAL, INTENT(in) :: t ! Time over which to propagate (typically dt/2)

    REAL :: x

    x = t * strain_rate ! Change in strain (dimensionless)

    r(1,:) = r(1,:) + x * r(2,:)        ! Extra strain term
    r(:,:) = r(:,:) + t * v(:,:) / box  ! Drift half-step (positions in box=1 units)
    strain = strain + x                 ! Advance strain and hence boundaries

    r(1,:) = r(1,:) - ANINT ( r(2,:) ) * strain ! Extra PBC correction (box=1 units)
    r(:,:) = r(:,:) - ANINT ( r(:,:) )          ! Periodic boundaries (box=1 units)

  END SUBROUTINE a_propagator

  SUBROUTINE b1_propagator ( t ) ! B1 propagator
    IMPLICIT NONE
    REAL, INTENT(in) :: t ! Time over which to propagate (typically dt/2)

    REAL :: x, c1, c2
    
    x = t * strain_rate ! Change in strain (dimensionless)

    c1 = x * SUM ( v(1,:)*v(2,:) ) / SUM ( v(:,:)**2 )
    c2 = ( x**2 ) * SUM ( v(2,:)**2 ) / SUM ( v(:,:)**2 )

    v(1,:) = v(1,:) - x*v(2,:)
    v(:,:) = v(:,:) / SQRT ( 1.0 - 2.0*c1 + c2 )

  END SUBROUTINE b1_propagator

  SUBROUTINE b2_propagator ( t ) ! B2 propagator
    IMPLICIT NONE
    REAL, INTENT(in) :: t ! Time over which to propagate (typically dt)

    REAL :: alpha, beta, h, e, dt_factor, prefactor
    
    alpha = SUM ( f(:,:)*v(:,:) ) / SUM ( v(:,:)**2 )
    beta  = SQRT ( SUM ( f(:,:)**2 ) / SUM ( v(:,:)**2 ) )
    h     = ( alpha + beta ) / ( alpha - beta )
    e     = EXP ( -beta * t )

    dt_factor = ( 1 + h - e - h / e ) / ( ( 1 - h ) * beta )
    prefactor = ( 1 - h ) / ( e - h / e )

    v(:,:) = prefactor * ( v(:,:) + dt_factor * f(:,:) )

  END SUBROUTINE b2_propagator

  SUBROUTINE calculate ( string ) 
    USE md_module, ONLY : potential_lrc, pressure_lrc
    IMPLICIT NONE
    CHARACTER (len=*), INTENT(in), OPTIONAL :: string

    ! This routine calculates variables of interest and (optionally) writes them out

    REAL :: kin

    kin = 0.5*SUM(v**2) ! NB v(:,:) are taken to be peculiar velocities
    tk  = 2.0 * kin / REAL ( 3*(n-1) )

    en_s = ( pot + kin ) / REAL ( n )
    en_f = ( cut + kin ) / REAL ( n ) + potential_lrc ( density, r_cut )
    p_s  = density * tk + vir / box**3
    p_f  = p_s + pressure_lrc ( density, r_cut )

    tc = SUM(f**2) / lap

    IF ( PRESENT ( string ) ) THEN
       WRITE ( unit=output_unit, fmt='(a)'           ) string
       WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'E/N (cut&shift)', en_s
       WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'P (cut&shift)',   p_s
       WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'E/N (full)',      en_f
       WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'P (full)',        p_f
       WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'T (kin)',         tk
       WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'T (con)',         tc
    END IF

  END SUBROUTINE calculate

END PROGRAM md_nvt_lj_le

