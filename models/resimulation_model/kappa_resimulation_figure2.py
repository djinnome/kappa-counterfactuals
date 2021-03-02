from pysb import Monomer, Parameter, Rule, Observable, Model, Initial
# instantiate a model
Model()

# declare monomers
Monomer('S', ['d', 'x'], {'x': ['u', 'p']})
K = Monomer('K', ['d', 'x'], {'x': ['u', 'p']})

# input the parameter values
Parameter('off_rate_fast', 1000)
Parameter('off_rate_slow', 1)
Parameter('mod_rate', 5)
Parameter('mod_rate_slow', 0.05)
Parameter('on_rate', 1)

# now input the rules
Rule('pK', K(x='u')  >> K(x='p'), mod_rate_slow)
Rule('b', K(d=None) + S(d=None) >> K(d=1) % S(d=1), on_rate)
Rule('u', K(d=1,x='u') % S(d=1) >> K(d=None,x='u') + S(d=None), off_rate_fast)
Rule('u_slow',K(d=1,x='p') % S(d=1) >> K(d=None,x='p') + S(d=None), off_rate_slow)
Rule('p', K(d=1) % S(d=1,x='u') >>  K(d=1) % S(d=1,x='p'), mod_rate)

Parameter('K_0', 1000)
Parameter('S_0', 100)
Initial(K(x='u', d=None), K_0)
Initial(S(x='u', d=None), S_0)

Observable('obsK', K(x='u'))   
Observable('obsS', S(x='u'))
